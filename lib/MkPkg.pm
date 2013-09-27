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
    rpmspec       => '[% SET tmpl = project _ ".spec"; INCLUDE $tmpl -%]',
    build         => '[% INCLUDE build -%]',
    notmpl        => [ qw(distribution output_dir projects_dir) ],
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
    my $dir = getcwd;
    while ($dir ne '/') {
        if (-f "$dir/mkpkg.conf") {
            return "$dir/mkpkg.conf";
        }
        $dir = dirname($dir);
    }
    exit_error("Can't find config file");
}

sub path {
    ( $_[0] =~ m|^/| ) ? $_[0] : "$config->{basedir}/$_[0]";
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
    my ($name, $project) = @_;
    my $res = config($name, ['run'], ['projects', $project]);
    if (ref $res || notmpl($name, $project)) {
        return $res;
    }
    return process_template($project, $res);
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
    open(my $g = IO::Handle->new, '-|') 
        || exec 'git', 'log', "--format=format:%G?\n%GG", -1, $chash;
    return undef if (<$g> ne "G\n");
    return (<$g> =~ m/^gpg: Signature made .+ using .+ key ID ([\dA-F]+)$/)
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
    if (!$config->{projects}{$project}{fetched}) {
        system('git', 'checkout', '-q', '--detach', 'master') == 0
                || exit_error "Error checking out master";
        system('git', 'fetch', 'origin', '+refs/heads/*:refs/heads/*') == 0
                || exit_error "Error fetching git repository";
        system('git', 'fetch', 'origin', '+refs/tags/*:refs/tags/*') == 0
                || exit_error "Error fetching git repository";
        $config->{projects}{$project}{fetched} = 1;
    }
}

sub version_command {
    my ($project, $git_hash) = @_;
    my $version_cmd = project_config('version_command', $project);
    return undef unless $version_cmd;
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'checkout', $git_hash);
    exit_error "Cannot checkout $git_hash" unless $success;
    ($stdout, $stderr, $success, $exit_code)
        = capture_exec($version_cmd);
    chdir($old_cwd);
    chomp $stdout;
    return $success ? $stdout : undef;
}

sub set_project_version {
    my ($project, $git_hash) = @_;
    return if project_config('version', $project);
    exit_error "No version or git_hash specified" unless $git_hash;
    $config->{projects}{$project}{version} = 
           version_command($project, $git_hash)
        || $config->{projects}{$project}{describe}{tag}
        || exit_error "No version specified";
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
    set_project_version($project, $git_hash);
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
        config   => $config,
        project  => $project,
        p        => $config->{projects}{$project},
        d        => $config->{distributions}{$distribution},
        c        => sub { project_config($_[0], $project) },
        dest_dir => $dest_dir,
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
    set_project_version($project, $git_hash);
    my $rpmspec = process_template($project,
                        project_config('rpmspec', $project), $dest_dir);
    write_file("$dest_dir/$project.spec", $rpmspec);
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
    system('rpmbuild', $action, '--define', "_topdir $tmpdir",
        '--define', "_sourcedir $tmpdir",
        '--define', "_srcrpmdir $dest_dir", '--define', "_rpmdir $dest_dir",
        "$tmpdir/$project.spec") == 0
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
