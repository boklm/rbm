package MkPkg;

use warnings;
use strict;
use Cwd qw(abs_path getcwd);
use YAML qw(LoadFile);
use Template;
use File::Basename;
use IO::Handle;
use IO::CaptureOutput qw(capture_exec);
use File::Temp;
use File::Copy;
use File::Slurp;
#use Data::Dump qw/dd/;

my %default_config = (
    projects_dir  => 'projects',
    output_dir    => 'out',
    git_clone_dir => 'git_clones',
    fetch         => 1,
    rpmspec       => '[% SET tmpl = project _ ".spec"; INCLUDE $tmpl -%]',
    build         => '[% INCLUDE build -%]',
    notmpl        => [ qw(distribution output_dir projects_dir) ],
    opt           => {},
    timestamp     => '[% exec("git show --format=format:%ct " _ c("git_hash") _ "^{commit} | head -1") %]',
    version       => <<END,
[%-
    IF c('version_command');
        exec(c('version_command'));
    ELSIF c(['describe', 'tag']);
        c(['describe', 'tag']);
    ELSE;
        exit_error('No version specified');
    END;
-%]
END
    rpmbuild      => <<END,
#!/bin/sh
set -e -x
[% SET srcdir = c('rpmbuild_srcdir') -%]
rpmbuild [% c('rpmbuild_action') %] --define '_topdir [% srcdir %]' \\
        --define '_sourcedir [% srcdir %]' \\
        --define '_srcrpmdir [% dest_dir %]' \\
        --define '_rpmdir [% dest_dir %]' \\
        '[% srcdir %]/[% project %].spec'
END
);

our $config;
sub load_config {
    my $config_file = shift // find_config_file();
    $config = { %default_config, %{ LoadFile($config_file) } };
    $config->{basedir} = dirname($config_file);
    foreach my $p (glob path($config->{projects_dir}) . '/*') {
        next unless -f "$p/config";
        $config->{projects}{basename($p)} = LoadFile("$p/config");
    }
}

sub find_config_file {
    for (my $dir = getcwd; $dir ne '/'; $dir = dirname($dir)) {
        return "$dir/mkpkg.conf" if -f "$dir/mkpkg.conf";
    }
    exit_error("Can't find config file");
}

sub path {
    my ($path, $basedir) = @_;
    $basedir //= $config->{basedir};
    return ( $path =~ m|^/| ) ? $path : "$basedir/$path";
}

sub config_p {
    my $c = $config;
    foreach my $p (@_) {
        return undef unless $c->{$p};
        $c = $c->{$p};
    }
    return $c;
}

sub config {
    my $name = shift;
    $name = [ $name ] unless ref $name eq 'ARRAY';
    foreach my $path (@_) {
        if (my $r = config_p(@$path, @$name)) {
            return $r;
        }
    }
    return config_p(@$name);
}

sub notmpl {
    my ($name, $project) = @_;
    return 1 if $name eq 'notmpl';
    my @n = (@{$config->{notmpl}}, @{project_config('notmpl', $project)});
    return grep { $name eq $_ } @n;
}

sub project_config {
    my ($name, $project, $options) = @_;
    my $opt_save = $config->{opt};
    $config->{opt} = { %{$config->{opt}}, %$options } if $options;
    my $res = config($name, ['opt'], ['run'], ['projects', $project]);
    if (!ref $res && !notmpl($name, $project)) {
        $res = process_template($project, $res);
    }
    $config->{opt} = $opt_save;
    return $res;
}

sub exit_error {
    print STDERR "Error: ", $_[0], "\n";
    exit (exists $_[1] ? $_[1] : 1);
}

sub get_distribution {
    my ($project) = @_;
    my $distribution = project_config('distribution', $project)
                || exit_error 'No distribution specified';
    exists $config->{distributions}{$distribution}
                || exit_error "Unknown distribution $distribution";
    return $distribution;
}

sub git_commit_sign_id {
    my $chash = shift;
    my ($stdout, $stderr, $success, $exit_code) =
        capture_exec('git', 'log', "--format=format:%G?\n%GG", -1, $chash);
    return undef unless $success;
    my @l = split /\n/, $stdout;
    return undef unless @l >= 2;
    return undef unless $l[0] =~ m/^[GU]$/;
    return ($l[1] =~ m/^gpg: Signature made .+ using .+ key ID ([\dA-F]+)$/)
        ? $1 : undef;
}

sub git_tag_sign_id {
    my $tag = shift;
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'tag', '-v', $tag);
    return undef unless $success;
    my $id;
    foreach my $l (split /\n/, $stderr) {
        next unless $l =~ m/^gpg:/;
        if ($l =~ m/^gpg: Signature made .+ using .+ key ID ([\dA-F]+)$/) {
            $id = $1;
        } elsif ($l =~ m/^gpg: Good signature from/) {
            return $id;
        }
    }
    return undef;
}

sub git_describe {
    my ($project, $git_hash) = @_;
    return if $config->{projects}{$project}{describe};
    $config->{projects}{$project}{describe} = {};
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'describe', '--long', $git_hash);
    if ($success) {
        (   $config->{projects}{$project}{describe}{tag},
            $config->{projects}{$project}{describe}{tag_reach},
            $config->{projects}{$project}{describe}{hash}
        ) = $stdout =~ m/^(.+)-(\d+)-g([^-]+)$/;
    }
    chdir($old_cwd);
}

sub valid_id {
    my ($id, $valid_id) = @_;
    if (ref $valid_id eq 'ARRAY') {
        foreach my $v (@$valid_id) {
            return 1 if $id eq $v;
        }
        return undef;
    }
    return $id eq $valid_id;
}

sub valid_project {
    my ($project) = @_;
    exists $config->{projects}{$project}
        || exit_error "Unknown project $project";
}

sub git_clone_fetch_chdir {
    my $project = shift;
    my $clonedir = path(project_config('git_clone_dir', $project));
    if (!chdir path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        if (system('git', 'clone',
                $config->{projects}{$project}{git_url}, $project) != 0) {
            exit_error "Error cloning $config->{projects}{$project}{git_url}";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    if (!$config->{projects}{$project}{fetched} && project_config('fetch', $project)) {
        system('git', 'checkout', '-q', '--detach', 'master') == 0
                || exit_error "Error checking out master";
        system('git', 'fetch', 'origin', '+refs/heads/*:refs/heads/*') == 0
                || exit_error "Error fetching git repository";
        system('git', 'fetch', 'origin', '+refs/tags/*:refs/tags/*') == 0
                || exit_error "Error fetching git repository";
        $config->{projects}{$project}{fetched} = 1;
    }
}

sub run_script {
    my ($cmd, $f) = @_;
    $f //= \&capture_exec;
    my @res;
    if ($cmd =~ m/^#/) {
        my (undef, $tmp) = File::Temp::tempfile();
        write_file($tmp, $cmd);
        chmod 0700, $tmp;
        @res = $f->($tmp);
        unlink $tmp;
    } else {
        @res = $f->($cmd);
    }
    return @res;
}

sub execute {
    my ($project, $cmd) = @_;
    my $git_hash = project_config('git_hash', $project)
        || exit_error 'No git_hash specified';
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'checkout', $git_hash);
    exit_error "Cannot checkout $git_hash" unless $success;
    ($stdout, $stderr, $success, $exit_code)
                = run_script($cmd, \&capture_exec);
    chdir($old_cwd);
    chomp $stdout;
    return $success ? $stdout : undef;
}

sub maketar {
    my ($project, $dest_dir) = @_;
    $dest_dir //= abs_path(path(project_config('output_dir', $project)));
    valid_project($project);
    my $git_hash = project_config('git_hash', $project)
        || exit_error 'No git_hash specified';
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    git_describe($project, $git_hash);
    my $version = project_config('version', $project);
    if (my $tag_gpg_id = project_config('tag_gpg_id', $project)) {
        my $id = git_tag_sign_id($git_hash) ||
                exit_error "$git_hash is not a signed tag";
        if (!valid_id($id, $tag_gpg_id)) {
            exit_error "$git_hash is not signed with a valid key";
        }
        print "Tag $git_hash is signed with key $id\n";
    }
    if (my $commit_gpg_id = project_config('commit_gpg_id', $project)) {
        my $id = git_commit_sign_id($git_hash) ||
                exit_error "$git_hash is not a signed commit";
        if (!valid_id($id, $commit_gpg_id)) {
            exit_error "$git_hash is not signed with a valid key";
        }
        print "Commit $git_hash is signed with key $id\n";
    }
    my $tar_file = "$project-$version.tar";
    system('git', 'archive', "--prefix=$project-$version/",
        "--output=$dest_dir/$tar_file", $git_hash) == 0
        || exit_error 'Error running git archive.';
    my %compress = (
        xz  => ['xz', '-f'],
        gz  => ['gzip', '-f'],
        bz2 => ['bzip2', '-f'],
    );
    if (my $c = project_config('compress_tar', $project)) {
        if (!defined $compress{$c}) {
            exit_error "Unknow compression $c";
        }
        system(@{$compress{$c}}, "$dest_dir/$tar_file") == 0
                || exit_error "Error compressing $tar_file with $compress{$c}->[0]";
        $tar_file .= ".$c";
    }
    my $timestamp = project_config('timestamp', $project);
    utime $timestamp, $timestamp, "$dest_dir/$tar_file" if $timestamp;
    print "Created $dest_dir/$tar_file\n";
    chdir($old_cwd);
}

sub process_template {
    my ($project, $tmpl, $dest_dir) = @_;
    $dest_dir //= abs_path(path(project_config('output_dir', $project)));
    my $distribution = get_distribution($project);
    my $projects_dir = abs_path(path(project_config('projects_dir', $project)));
    my $template = Template->new(
        ENCODING        => 'utf8',
        INCLUDE_PATH    => "$projects_dir/$project:$projects_dir/common",
    );
    my $vars = {
        config     => $config,
        project    => $project,
        p          => $config->{projects}{$project},
        d          => $config->{distributions}{$distribution},
        c          => sub { project_config($_[0], $project) },
        dest_dir   => $dest_dir,
        exit_error => \&exit_error,
        exec       => sub { execute($project, $_[0]) },
        path       => \&path,
    };
    my $output;
    $template->process(\$tmpl, $vars, \$output, binmode => ':utf8')
                    || exit_error "Template Error:\n" . $template->error;
    return $output;
}

sub rpmspec {
    my ($project, $dest_dir) = @_;
    $dest_dir //= abs_path(path(project_config('output_dir', $project)));
    valid_project($project);
    my $git_hash = project_config('git_hash', $project);
    git_describe($project, $git_hash) if $git_hash;
    my $timestamp = project_config('timestamp', $project);
    my $rpmspec = process_template($project,
                        project_config('rpmspec', $project), $dest_dir);
    write_file("$dest_dir/$project.spec", $rpmspec);
    utime $timestamp, $timestamp, "$dest_dir/$project.spec" if $timestamp;
}

sub projectslist {
    keys %{$config->{projects}};
}

sub copy_files {
    my ($project, $dest_dir) = @_;
    my $copy_files = project_config('copy_files', $project);
    return unless $copy_files;
    my $proj_dir = abs_path(path(project_config('projects_dir', $project)));
    my $src_dir = "$proj_dir/$project";
    foreach my $file (@$copy_files) {
        copy("$src_dir/$file", "$dest_dir/$file");
    }
}

sub rpmbuild {
    my ($project, $action, $dest_dir) = @_;
    $dest_dir //= abs_path(path(project_config('output_dir', $project)));
    valid_project($project);
    my $tmpdir = File::Temp->newdir;
    maketar($project, $tmpdir->dirname);
    copy_files($project, $tmpdir->dirname);
    rpmspec($project, $tmpdir->dirname);
    my $options = {
        rpmbuild_action => $action,
        output_dir      => $dest_dir,
        rpmbuild_srcdir => $tmpdir->dirname,
    };
    my $rpmbuild = project_config('rpmbuild', $project, $options);
    run_script($rpmbuild, sub { system(@_) })
                || exit_error "Error running rpmbuild";
}

sub build {
    my ($project, $dest_dir) = @_;
    $dest_dir //= abs_path(path(project_config('output_dir', $project)));
    valid_project($project);
    my $projects_dir = abs_path(path(project_config('projects_dir', $project)));
    -f "$projects_dir/$project/build" || -f "$projects_dir/common/build"
        || exit_error "Cannot find build template";
    my $distribution = get_distribution($project);
    my $tmpdir = File::Temp->newdir;
    maketar($project, $tmpdir->dirname);
    copy_files($project, $tmpdir->dirname);
    rpmspec($project, $tmpdir->dirname);
    my $build = project_config('build', $project);
    write_file("$tmpdir/build", $build);
    my $old_cwd = getcwd;
    chdir $tmpdir->dirname;
    chmod 0700, 'build';
    my $res = system("$tmpdir/build");
    chdir $old_cwd;
    exit_error "Error running build script" unless $res == 0;
}

1;
