package BURPS;

use warnings;
use strict;
use Cwd qw(getcwd);
use YAML::XS qw(LoadFile);
use Template;
use File::Basename;
use IO::Handle;
use IO::CaptureOutput qw(capture_exec);
use File::Temp;
use File::Copy;
use File::Slurp;
use File::Path qw(make_path);
use String::ShellQuote;
use Sort::Versions;
use BURPS::DefaultConfig;
#use Data::Dump qw/dd/;

our $config;

sub load_config_file {
    my $res = {};
    my @conf;
    eval {
        @conf = LoadFile($_[0]);
    } or do {
        exit_error("Error reading file $_[0] :\n" . $@);
    };
    foreach my $c (@conf) {
        local $@ = '';
        $res = { %$res, %$c } if ref $c eq 'HASH';
        $res = { %$res, eval $c } if !ref $c;
        exit_error("Error executing perl config from $_[0] :\n" . $@) if $@;
    }
    return $res;
}

sub load_config {
    my $config_file = shift // find_config_file();
    $config = load_config_file($config_file);
    $config->{default} = \%default_config;
    $config->{basedir} = dirname($config_file);
    $config->{opt} = {};
    my $pdir = $config->{projects_dir} || $config->{default}{projects_dir};
    foreach my $p (glob path($pdir) . '/*') {
        next unless -f "$p/config";
        $config->{projects}{basename($p)} = load_config_file("$p/config");
    }
}

sub load_system_config {
    my ($project) = @_;
    my $cfile = project_config($project ? $project : 'undef', 'sysconf_file');
    $config->{system} = -f $cfile ? load_config_file($cfile) : {};
}

sub find_config_file {
    for (my $dir = getcwd; $dir ne '/'; $dir = dirname($dir)) {
        return "$dir/burps.conf" if -f "$dir/burps.conf";
    }
    exit_error("Can't find config file");
}

sub path {
    my ($path, $basedir) = @_;
    $basedir //= $config->{basedir};
    return ( $path =~ m|^/| ) ? $path : "$basedir/$path";
}

sub config_p {
    my $c = shift;
    my $project = shift;
    foreach my $p (@_) {
        return undef unless defined $c->{$p};
        $c->{$p} = $c->{$p}->($project, @_) if ref $c->{$p} eq 'CODE';
        $c = $c->{$p};
    }
    return $c;
}

sub match_distro {
    my ($project, $path, $name, $options) = @_;
    return () if $options->{no_distro};
    my $nodis = { no_distro => 1 };
    my $distros = config_p($config, $project, @$path, 'distributions');
    return () unless $distros;
    my (@res1, @res2, @res3, @res4);
    my $id = project_config($project, 'lsb_release/id', $nodis);
    my $release = project_config($project, 'lsb_release/release', $nodis);
    my $codename = project_config($project, 'lsb_release/codename', $nodis);
    foreach my $d (@$distros) {
        my %l = %{$d->{lsb_release}};
        next unless $l{id} eq $id;
        if (defined($l{release}) && $l{release} eq $release) {
            if (defined($l{codename}) && $l{codename} eq $codename) {
                push @res1, $d;
            } elsif (!defined($l{codename})) {
                push @res2, $d;
            }
        } elsif (!defined $l{release}) {
            if (defined($l{codename}) && $l{codename} eq $codename) {
                push @res3, $d;
            } elsif (!defined $l{codename}) {
                push @res4, $d;
            }
        }
    }
    return @res1, @res2, @res3, @res4;
}

sub config {
    my $project = shift;
    my $name = shift;
    my $options = shift;
    my $res;
    foreach my $path (@_) {
        my @l;
        my $target;
        if ($name->[0] ne 'target'
            && ($target = project_config($project, 'target', $options))) {
            $target = [ $target ] unless ref $target eq 'ARRAY';
            foreach my $t (ref $target eq 'ARRAY' ? @$target : $target) {
                push @l, map { config_p($_, $project, @$name) }
                        match_distro($project, [@$path, 'targets', $t],
                                                        $name, $options);
                push @l, config_p($config, $project, @$path, 'targets', $t, @$name);
            }
        }
        push @l, map { config_p($_, $project, @$name) }
                match_distro($project, $path, $name, $options);
        push @l, config_p($config, $project, @$path, @$name);
        @l = grep { defined $_ } @l;
        push @$res, @l if @l;
    }
    return $options->{as_array} ? $res : $res->[0];
}

sub notmpl {
    my ($name, $project) = @_;
    return 1 if $name eq 'notmpl';
    my @n = (@{$config->{default}{notmpl}},
        @{project_config($project, 'notmpl', { no_distro => 1 })});
    return grep { $name eq $_ } @n;
}

sub confkey_str {
    ref $_[0] eq 'ARRAY' ? join '/', @{$_[0]} : $_[0];
}

sub project_config {
    my ($project, $name, $options) = @_;
    $name = [ split '/', $name ] unless ref $name eq 'ARRAY';
    my $opt_save = $config->{opt};
    $config->{opt} = { %{$config->{opt}}, %$options } if $options;
    my $res = config($project, $name, $options, ['opt'], ['run'],
                        ['projects', $project], [], ['system'], ['default']);
    if (!$options->{no_tmpl} && defined($res) && !ref $res
        && !notmpl(confkey_str($name), $project)) {
        $res = process_template($project, $res,
            confkey_str($name) eq 'output_dir' ? '.' : undef);
    }
    $config->{opt} = $opt_save;
    if (!defined($res) && $options->{error_if_undef}) {
        my $msg = $options->{error_if_undef} eq '1' ?
                "Option " . confkey_str($name) . " is undefined"
                : $options->{error_if_undef};
        exit_error($msg);
    }
    return $res;
}

sub exit_error {
    print STDERR "Error: ", $_[0], "\n";
    exit (exists $_[1] ? $_[1] : 1);
}

sub set_git_gpg_wrapper {
    my ($project) = @_;
    my $w = project_config($project, 'gpg_wrapper');
    my (undef, $tmp) = File::Temp::tempfile(DIR =>
                        project_config($project, 'tmp_dir'));
    write_file($tmp, $w);
    chmod 0700, $tmp;
    system('git', 'config', 'gpg.program', $tmp) == 0
        || exit_error 'Error setting gpg.program';
    return $tmp;
}

sub unset_git_gpg_wrapper {
    unlink $_[0];
    system('git', 'config', '--unset', 'gpg.program') == 0
        || exit_error 'Error unsetting gpg.program';
}

sub git_commit_sign_id {
    my ($project, $chash) = @_;
    my $w = set_git_gpg_wrapper($project);
    my ($stdout, $stderr, $success, $exit_code) =
        capture_exec('git', 'log', "--format=format:%G?\n%GG", -1, $chash);
    unset_git_gpg_wrapper($w);
    return undef unless $success;
    my @l = split /\n/, $stdout;
    return undef unless @l >= 2;
    return undef unless $l[0] =~ m/^[GU]$/;
    foreach (@l) {
        if (m/^Primary key fingerprint:(.+)$/) {
            my $fp = $1;
            $fp =~ s/\s//g;
            return $fp;
        }
    }
    return undef;
}

sub git_tag_sign_id {
    my ($project, $tag) = @_;
    my $w = set_git_gpg_wrapper($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'tag', '-v', $tag);
    unset_git_gpg_wrapper($w);
    return undef unless $success;
    foreach my $l (split /\n/, $stderr) {
        if ($l =~ m/^Primary key fingerprint:(.+)$/) {
            my $fp = $1;
            $fp =~ s/\s//g;
            return $fp;
        }
    }
    return undef;
}

sub valid_id {
    my ($fp, $valid_id) = @_;
    if ($valid_id eq '1' || (ref $valid_id eq 'ARRAY' && @$valid_id == 1
            && $valid_id->[0] eq '1')) {
        return 1;
    }
    if (ref $valid_id eq 'ARRAY') {
        foreach my $v (@$valid_id) {
            return 1 if $fp =~ m/$v$/;
        }
        return undef;
    }
    return $fp =~ m/$valid_id$/;
}

sub valid_project {
    my ($project) = @_;
    exists $config->{projects}{$project}
        || exit_error "Unknown project $project";
}

sub create_dir {
    my ($directory) = @_;
    return $directory if -d $directory;
    my @res = make_path($directory);
    exit_error "Error creating $directory" unless @res;
    return $directory;
}

sub git_clone_fetch_chdir {
    my ($project, $options) = @_;
    my $clonedir = create_dir(path(project_config($project,
                                'git_clone_dir', $options)));
    if (!chdir path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        my $git_url = project_config($project, 'git_url', $options)
                || exit_error "git_url is undefined";
        if (system('git', 'clone', $git_url, $project) != 0) {
            exit_error "Error cloning $git_url";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    if (!$config->{projects}{$project}{fetched}
                && project_config($project, 'fetch', $options)) {
        system('git', 'checkout', '-q', '--detach') == 0
                || exit_error "Error running git checkout --detach";
        system('git', 'fetch', 'origin', '+refs/heads/*:refs/heads/*') == 0
                || exit_error "Error fetching git repository";
        system('git', 'fetch', 'origin', '+refs/tags/*:refs/tags/*') == 0
                || exit_error "Error fetching git repository";
        $config->{projects}{$project}{fetched} = 1;
    }
}

sub run_script {
    my ($project, $cmd, $f) = @_;
    $f //= \&capture_exec;
    my @res;
    if ($cmd =~ m/^#/) {
        my (undef, $tmp) = File::Temp::tempfile(DIR =>
                                project_config($project, 'tmp_dir'));
        write_file($tmp, $cmd);
        chmod 0700, $tmp;
        @res = $f->($tmp);
        unlink $tmp;
    } else {
        @res = $f->($cmd);
    }
    return @res == 1 ? $res[0] : @res;
}

sub execute {
    my ($project, $cmd, $options) = @_;
    my $git_hash = project_config($project, 'git_hash', $options)
        || exit_error 'No git_hash specified';
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project, $options);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'checkout', $git_hash);
    exit_error "Cannot checkout $git_hash" unless $success;
    ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
    chdir($old_cwd);
    chomp $stdout;
    return $success ? $stdout : undef;
}

sub gpg_id {
    my ($id) = @_;
    return $id unless $id;
    if (ref $id eq 'ARRAY' && @$id == 1 && !$id->[0]) {
        return 0;
    }
    return $id;
}

sub maketar {
    my ($project, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir', { no_distro => 1 })));
    valid_project($project);
    my $git_hash = project_config($project, 'git_hash')
        || exit_error 'No git_hash specified';
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my $version = project_config($project, 'version');
    if (my $tag_gpg_id = gpg_id(project_config($project, 'tag_gpg_id'))) {
        my $id = git_tag_sign_id($project, $git_hash) ||
                exit_error "$git_hash is not a signed tag";
        if (!valid_id($id, $tag_gpg_id)) {
            exit_error "Tag $git_hash is not signed with a valid key";
        }
        print "Tag $git_hash is signed with key $id\n";
    }
    if (my $commit_gpg_id = gpg_id(project_config($project, 'commit_gpg_id'))) {
        my $id = git_commit_sign_id($project, $git_hash) ||
                exit_error "$git_hash is not a signed commit";
        if (!valid_id($id, $commit_gpg_id)) {
            exit_error "Commit $git_hash is not signed with a valid key";
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
    if (my $c = project_config($project, 'compress_tar')) {
        if (!defined $compress{$c}) {
            exit_error "Unknow compression $c";
        }
        system(@{$compress{$c}}, "$dest_dir/$tar_file") == 0
                || exit_error "Error compressing $tar_file with $compress{$c}->[0]";
        $tar_file .= ".$c";
    }
    my $timestamp = project_config($project, 'timestamp');
    utime $timestamp, $timestamp, "$dest_dir/$tar_file" if $timestamp;
    print "Created $dest_dir/$tar_file\n";
    chdir($old_cwd);
    return $tar_file;
}

sub process_template {
    my ($project, $tmpl, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir', { no_distro => 1 })));
    my $projects_dir = path(project_config($project, 'projects_dir', { no_distro => 1 }));
    my $template = Template->new(
        ENCODING        => 'utf8',
        INCLUDE_PATH    => "$projects_dir/$project:$projects_dir/common",
    );
    my $vars = {
        config     => $config,
        project    => $project,
        p          => $config->{projects}{$project},
        c          => sub { project_config($project, @_) },
        dest_dir   => $dest_dir,
        exit_error => \&exit_error,
        exec       => sub { execute($project, @_) },
        path       => \&path,
        tmpl       => sub { process_template($project, $_[0], $dest_dir) },
        shell_quote => \&shell_quote,
        versioncmp  => \&versioncmp,
    };
    my $output;
    $template->process(\$tmpl, $vars, \$output, binmode => ':utf8')
                    || exit_error "Template Error:\n" . $template->error;
    return $output;
}

sub rpmspec {
    my ($project, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir')));
    valid_project($project);
    my $git_hash = project_config($project, 'git_hash');
    my $timestamp = project_config($project, 'timestamp');
    my $rpmspec = project_config($project, 'rpmspec')
                || exit_error "Undefined config for rpmspec";
    write_file("$dest_dir/$project.spec", $rpmspec);
    utime $timestamp, $timestamp, "$dest_dir/$project.spec" if $timestamp;
}

sub projectslist {
    keys %{$config->{projects}};
}

sub copy_files {
    my ($project, $dest_dir) = @_;
    my @r;
    my $copy_files = project_config($project, 'copy_files');
    return unless $copy_files;
    my $proj_dir = path(project_config($project, 'projects_dir'));
    my $src_dir = "$proj_dir/$project";
    foreach my $file (@$copy_files) {
        copy("$src_dir/$file", "$dest_dir/$file");
        push @r, $file;
    }
    return @r;
}

sub build_run {
    my ($project, $script_name, $options) = @_;
    my $error;
    my $dest_dir = create_dir(path(project_config($project, 'output_dir', $options)));
    valid_project($project);
    my $old_cwd = getcwd;
    my $srcdir = project_config($project, 'build_srcdir', $options);
    my $tmpdir = File::Temp->newdir(project_config($project, 'tmp_dir', $options)
                                . '/burps-XXXXX');
    my @cfiles;
    if ($srcdir) {
        @cfiles = ($srcdir);
    } else {
        $srcdir = $tmpdir->dirname;
        push @cfiles, 'build';
        push @cfiles, maketar($project, $srcdir);
        push @cfiles, copy_files($project, $srcdir);
    }
    my ($remote_tmp_src, $remote_tmp_dst, $build_script);
    if (project_config($project, "remote/$script_name", $options)) {
        foreach my $remote_tmp ($remote_tmp_src, $remote_tmp_dst) {
            my $cmd = project_config($project, "remote/$script_name/exec", {
                    %$options,
                    exec_cmd => project_config($project,
                        "remote/$script_name/mktmpdir", $options) || 'mktemp -d',
                });
            my ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
            if (!$success) {
                $error = "Error connecting to remote";
                goto EXIT;
            }
            $remote_tmp = (split("\n", $stdout))[0];
        }
        $build_script = project_config($project, $script_name, {
                %$options,
                output_dir => $remote_tmp_dst,
            });
    } else {
        $build_script = project_config($project, $script_name, $options);
    }
    if (!$build_script) {
        $error = "Missing $script_name config";
        goto EXIT;
    }
    write_file("$srcdir/build", $build_script);
    chdir $srcdir;
    chmod 0700, 'build';
    my $res;
    if ($remote_tmp_src && $remote_tmp_dst) {
        foreach my $file (@cfiles) {
            my $cmd = project_config($project, "remote/$script_name/put", {
                    %$options,
                    put_src => "$srcdir/$file",
                    put_dst => $remote_tmp_src,
                });
            if (run_script($project, $cmd, sub { system(@_) }) != 0) {
                $error = "Error uploading $file";
                goto EXIT;
            }
        }
        my $cmd = project_config($project, "remote/$script_name/exec", {
                %$options,
                exec_cmd => "cd $remote_tmp_src; ./build",
            });
        if (run_script($project, $cmd, sub { system(@_) }) != 0) {
            $error = "Error running $script_name";
            goto EXIT;
        }
        $cmd = project_config($project, "remote/$script_name/get", {
                %$options,
                get_src => "$remote_tmp_dst/*",
                get_dst => $dest_dir,
            });
        if (run_script($project, $cmd, sub { system(@_) }) != 0) {
            $error = "Error downloading build result";
        }
        run_script($project, project_config($project, "remote/$script_name/exec", {
                %$options,
                exec_cmd => "rm -Rf $remote_tmp_src $remote_tmp_dst",
            }), \&capture_exec);
    } else {
        if (system("$srcdir/build") != 0) {
            $error = "Error running $script_name";
        }
    }
    EXIT:
    chdir $old_cwd;
    exit_error $error if $error;
}

sub build_pkg {
    my ($project, $options) = @_;
    build_run($project, project_config($project, 'pkg_type', $options), $options);
}

sub publish {
    my ($project) = @_;
    project_config($project, 'publish', { error_if_undef => 1 });
    my $publish_src_dir = project_config($project, 'publish_src_dir');
    if (!$publish_src_dir) {
        $publish_src_dir = File::Temp->newdir(project_config($project, 'tmp_dir')
                                . '/burps-XXXXXX');
        build_pkg($project, {output_dir => $publish_src_dir});
    }
    build_run($project, 'publish', { build_srcdir => $publish_src_dir });
}

1;
