package RBM;

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
use File::Basename;
use String::ShellQuote;
use Sort::Versions;
use RBM::DefaultConfig;
use Digest::SHA qw(sha256_hex);
use Data::UUID;
use Data::Dump qw(dd pp);

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
    $config->{step} = 'init';
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
        return "$dir/rbm.conf" if -f "$dir/rbm.conf";
    }
    exit_error("Can't find config file");
}

sub path {
    my ($path, $basedir) = @_;
    $basedir //= $config->{basedir};
    return ( $path =~ m|^/| ) ? $path : "$basedir/$path";
}

sub config_p {
    my ($c, $project, $options, @q) = @_;
    foreach my $p (@q) {
        return undef unless ref $c eq 'HASH';
        return undef unless defined $c->{$p};
        $c = ref $c->{$p} eq 'CODE' ? $c->{$p}->($project, $options, @_) : $c->{$p};
    }
    return $c;
}

sub match_distro {
    my ($project, $path, $name, $options) = @_;
    return () if $options->{no_distro};
    my $nodis = { no_distro => 1 };
    my $distros = config_p($config, $project, $options, @$path, 'distributions');
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

sub as_array {
    ref $_[0] eq 'ARRAY' ? $_[0] : [ $_[0] ];
}

sub get_target {
    my ($project, $options, $paths, $target) = @_;
    my @res;
    foreach my $path (@$paths) {
        foreach my $step ([ 'steps', $config->{step} ], []) {
            my $z = config_p($config, $project, $options, @$path, @$step,
                             'targets', $target);
            next unless $z;
            if (ref $z eq 'HASH') {
                push @res, $target unless grep { $_ eq $target } @res;
                next;
            }
            my @z = ref $z eq 'ARRAY' ? (@{$z}) : ($z);
            push @res, map { @{get_target($project, $options, $paths, $_)} } @z;
        }
    }
    return \@res;
}

sub get_targets {
    my ($project, $options, $paths) = @_;
    my $tmp = $config->{run}{target} ? as_array($config->{run}{target}) : [ 'notarget' ];
    $tmp = [ map { m/^$project:(.+)$/ ? $1 : $_ } @$tmp ];
    return [ map { @{get_target($project, $options, $paths, $_)} } @$tmp ];
}

sub get_step {
    my ($project, $options, $step, $paths) = @_;
    foreach my $path (@$paths) {
        my $z = config_p($config, $project, $options, @$path, 'steps', $step);
        next unless $z;
        return $step if ref $z;
        return get_step($project, $options, $z, $paths);
    }
    return $step;
}

sub config {
    my $project = shift;
    my $name = shift;
    my $options = shift;
    my $res;
    my @targets = @{get_targets($project, $options, \@_)};
    my @step = ('steps', get_step($project, $options, $config->{step}, \@_));
    foreach my $path (@_) {
        my @l;
        # 1st priority: targets + step matching
        foreach my $t (@targets) {
            push @l, map { config_p($_, $project, $options, @$name) }
              match_distro($project, [@$path, @step, 'targets', $t], $name, $options);
            push @l, config_p($config, $project, $options, @$path, @step, 'targets', $t, @$name);
        }
        # 2nd priority: step maching
        push @l, map { config_p($_, $project, $options, @$name) }
                match_distro($project, [@$path, @step], $name, $options);
        push @l, config_p($config, $project, $options, @$path, @step, @$name);
        # 3rd priority: target matching
        foreach my $t (@targets) {
            push @l, map { config_p($_, $project, $options, @$name) }
              match_distro($project, [@$path, 'targets', $t], $name, $options);
            push @l, config_p($config, $project, $options, @$path, 'targets', $t, @$name);
        }
        # last priority: no target and no step matching
        push @l, map { config_p($_, $project, $options, @$name) }
                match_distro($project, $path, $name, $options);
        push @l, config_p($config, $project, $options, @$path, @$name);
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
    my $error_if_undef = $options->{error_if_undef};
    $options = $options ? {%$options, error_if_undef => 0} : $options;
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
    if (!defined($res) && $error_if_undef) {
        my $msg = $error_if_undef eq '1' ?
                "Option " . confkey_str($name) . " is undefined"
                : $error_if_undef;
        exit_error($msg);
    }
    return $res;
}

sub project_step_config {
    my $run_save = $config->{run};
    my $step_save = $config->{step};
    if ($_[2] && $_[2]->{step}) {
        $config->{step} = $_[2]->{step};
    }
    $config->{run} = { target => $_[2]->{target} };
    $config->{run}{target} //= $run_save->{target};
    my $res = project_config(@_);
    $config->{run} = $run_save;
    $config->{step} = $step_save;
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

sub gpg_get_fingerprint {
    foreach my $l (@_) {
        if ($l =~ m/^Primary key fingerprint:(.+)$/) {
            my $fp = $1;
            $fp =~ s/\s//g;
            return $fp;
        }
    }
    return undef;
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
    return gpg_get_fingerprint(@l);
}

sub git_tag_sign_id {
    my ($project, $tag) = @_;
    my $w = set_git_gpg_wrapper($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'tag', '-v', $tag);
    unset_git_gpg_wrapper($w);
    return undef unless $success;
    return gpg_get_fingerprint(split /\n/, $stderr);
}

sub file_sign_id {
    my ($project, $options) = @_;
    my (undef, $gpg_wrapper) = File::Temp::tempfile(DIR =>
                        project_config($project, 'tmp_dir', $options));
    write_file($gpg_wrapper, project_config($project, 'gpg_wrapper', $options));
    chmod 0700, $gpg_wrapper;
    my ($stdout, $stderr, $success, $exit_code) =
        capture_exec($gpg_wrapper, '--verify',
            project_config($project, 'filename_sig', $options));
    return undef unless $success;
    return gpg_get_fingerprint(split /\n/, $stderr);
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
    my $git_url = project_config($project, 'git_url', $options)
                || exit_error "git_url is undefined";
    if (!chdir path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        if (system('git', 'clone', $git_url, $project) != 0) {
            exit_error "Error cloning $git_url";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    if (!$config->{projects}{$project}{fetched}
                && project_config($project, 'fetch', $options)) {
        system('git', 'remote', 'set-url', 'origin', $git_url) == 0
                || exit_error "Error setting git remote";
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
    my $old_cwd = getcwd;
    if (project_config($project, 'git_url', $options)) {
        my $git_hash = project_config($project, 'git_hash', $options)
                || exit_error "No git_hash specified for project $project";
        git_clone_fetch_chdir($project, $options);
        my ($stdout, $stderr, $success, $exit_code)
                = capture_exec('git', 'checkout', $git_hash);
        exit_error "Cannot checkout $git_hash" unless $success;
    }
    my ($stdout, $stderr, $success, $exit_code)
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
    my ($project, $options, $dest_dir) = @_;
    $options //= {};
    $dest_dir //= create_dir(path(project_config($project, 'output_dir',
                { %$options, no_distro => 1 })));
    valid_project($project);
    return undef unless project_config($project, 'git_url', $options);
    my $git_hash = project_config($project, 'git_hash', $options)
        || exit_error "No git_hash specified for project $project";
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my $version = project_config($project, 'version', $options);
    if (my $tag_gpg_id = gpg_id(project_config($project, 'tag_gpg_id', $options))) {
        my $id = git_tag_sign_id($project, $git_hash) ||
                exit_error "$git_hash is not a signed tag";
        if (!valid_id($id, $tag_gpg_id)) {
            exit_error "Tag $git_hash is not signed with a valid key";
        }
        print "Tag $git_hash is signed with key $id\n";
    }
    if (my $commit_gpg_id = gpg_id(project_config($project, 'commit_gpg_id',
                $options))) {
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
    if (my $c = project_config($project, 'compress_tar', $options)) {
        if (!defined $compress{$c}) {
            exit_error "Unknow compression $c";
        }
        system(@{$compress{$c}}, "$dest_dir/$tar_file") == 0
                || exit_error "Error compressing $tar_file with $compress{$c}->[0]";
        $tar_file .= ".$c";
    }
    my $timestamp = project_config($project, 'timestamp', $options);
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
        pc         => \&project_step_config,
        dest_dir   => $dest_dir,
        exit_error => \&exit_error,
        exec       => sub { execute($project, @_) },
        path       => \&path,
        tmpl       => sub { process_template($project, $_[0], $dest_dir) },
        shell_quote => \&shell_quote,
        versioncmp  => \&versioncmp,
        sha256      => \&sha256_hex,
        fileparse   => \&fileparse,
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

sub urlget {
    my ($project, $input_file, $exit_on_error) = @_;
    my $cmd = project_config($project, 'urlget', $input_file);
    my $success = run_script($project, $cmd, sub { system(@_) }) == 0;
    if (!$success) {
        unlink project_config($project, 'filename', $input_file);
        exit_error "Error downloading file" if $exit_on_error;
    }
    return $success;
}

sub is_url {
    $_[0] =~ m/^https?:\/\/.*/;
}

sub file_in_dir {
    my ($filename, @dir) = @_;
    return map { -f "$_/$filename" ? "$_/$filename" : () } @dir;
}

sub input_files {
    my ($project, $options, $dest_dir) = @_;
    my @res;
    my $input_files = project_config($project, 'input_files', $options,);
    return unless $input_files;
    my $proj_dir = path(project_config($project, 'projects_dir', $options));
    my $src_dir = "$proj_dir/$project";
    my $old_cwd = getcwd;
    chdir $src_dir || exit_error "cannot chdir to $src_dir";
    foreach my $input_file (@$input_files) {
        if (!ref $input_file) {
            $input_file = project_config($project,
                process_template($project, $input_file), $options);
        }
        next unless $input_file;
        my $t = sub {
            project_config($project, $_[0], {$options ? %$options : (),
                    %$input_file, output_dir => $src_dir});
        };
        if ($input_file->{enable} && !$t->('enable')) {
            next;
        }
        $input_file->{origin_project} = $project;
        my $proj_out_dir = path(project_config(
                $t->('project') ? $t->('project') : $project,
                'output_dir', {$options ? %$options : (), %$input_file}));
        my $url = $t->('URL');
        my $name = $input_file->{filename} ? $t->('filename') :
                   $url ? basename($url) :
                   undef;
        $name //= project_step_config($t->('project'), 'filename',
            {$options ? %$options : (), step => $t->('pkg_type'),
                %$input_file}) if $t->('project');
        $input_file->{filename} //= $name;
        exit_error("Missing filename:\n" . pp($input_file)) unless $name;
        my ($fname) = file_in_dir($name, $src_dir, $proj_out_dir);
        my $file_gpg_id = gpg_id($t->('file_gpg_id'));
        if (!$fname || $t->('refresh_input')) {
            if ($t->('content')) {
                write_file("$proj_out_dir/$name", $t->('content'));
            } elsif ($t->('URL')) {
                urlget($project, $input_file, 1);
            } elsif ($t->('exec')) {
                if (run_script($project, $t->('exec'),
                        sub { system(@_) }) != 0) {
                    exit_error "Error creating $name";
                }
            } elsif ($t->('project')) {
                my $p = $t->('project');
                print "Building project $p\n";
                my $run_save = $config->{run};
                $config->{run} = { target => $input_file->{target} };
                $config->{run}{target} //= $run_save->{target};
                build_pkg($p, {%$input_file, output_dir => $proj_out_dir});
                $config->{run} = $run_save;
                print "Finished build of project $p\n";
            } else {
                dd $input_file;
                exit_error "Missing file $name";
            }
        }
        ($fname) = file_in_dir($name, $src_dir, $proj_out_dir);
        exit_error "Missing file $name" unless $fname;
        if ($t->('sha256sum')
            && $t->('sha256sum') ne sha256_hex(read_file($fname))) {
            exit_error "Wrong sha256sum for $fname.\n" .
                       "Expected sha256sum: " . $t->('sha256sum');
        }
        if ($file_gpg_id) {
            my $sig_ext = $t->('sig_ext');
            $sig_ext = ref $sig_ext eq 'ARRAY' ? $sig_ext : [ $sig_ext ];
            my $sig_file;
            foreach my $s (@$sig_ext) {
                if (-f "$fname.$s" && !$t->('refresh_input')) {
                    $sig_file = "$fname.$s";
                    last;
                }
            }
            foreach my $s ($sig_file ? () : @$sig_ext) {
                if ($url) {
                    my $f = { %$input_file, URL => "$url.$s",
                        filename => "$input_file->{filename}.$s" };
                    if (urlget($project, $f, 0)) {
                        $sig_file = "$fname.$s";
                        last;
                    }
                }
            }
            exit_error "No signature file for $name" unless $sig_file;
            my $id = file_sign_id($project, { %$input_file,
                    filename_sig => $sig_file });
            print "File $name is signed with id $id\n" if $id;
            if (!$id || !valid_id($id, $file_gpg_id)) {
                exit_error "File $name is not signed with a valid key";
            }
        }
        print "Using file $fname\n";
        copy($fname, "$dest_dir/$name");
        push @res, $name;
    }
    chdir $old_cwd;
    return @res;
}

sub build_run {
    my ($project, $script_name, $options) = @_;
    my $old_step = $config->{step};
    $config->{step} = $script_name;
    $options //= {};
    my $error;
    my $dest_dir = create_dir(path(project_config($project, 'output_dir', $options)));
    valid_project($project);
    $options = { %$options, build_id => Data::UUID->new->create_str };
    my $old_cwd = getcwd;
    my $srcdir = project_config($project, 'build_srcdir', $options);
    my $use_srcdir = $srcdir;
    my $tmpdir = File::Temp->newdir(project_config($project, 'tmp_dir', $options)
                                . '/rbm-XXXXX');
    my @cfiles;
    if ($use_srcdir) {
        @cfiles = ($srcdir);
    } else {
        $srcdir = $tmpdir->dirname;
        my $tarfile = maketar($project, $options, $srcdir);
        push @cfiles, $tarfile if $tarfile;
        push @cfiles, copy_files($project, $srcdir);
        push @cfiles, input_files($project, $options, $srcdir);
    }
    my ($remote_tmp_src, $remote_tmp_dst, %build_script);
    my @scripts = ('pre', $script_name, 'post');
    my %scripts_root = ( pre => 1, post => 1);
    if (project_config($project, "remote_exec", $options)) {
        my $cmd = project_config($project, "remote_start", $options);
        if ($cmd) {
            my ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
            if (!$success) {
                $error = "Error starting remote";
                goto EXIT;
            }
        }
        foreach my $remote_tmp ($remote_tmp_src, $remote_tmp_dst) {
            $cmd = project_config($project, "remote_exec", {
                    %$options,
                    exec_cmd => project_config($project,
                        "remote_mktemp", $options) || 'mktemp -d',
                    exec_name => 'mktemp',
                    exec_as_root => 0,
                });
            my ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
            if (!$success) {
                $error = "Error connecting to remote:\n$stderr";
                goto EXIT;
            }
            $remote_tmp = (split(/\r?\n/, $stdout))[0];
        }
        my $o = {
            %$options,
            output_dir => $remote_tmp_dst,
        };
        foreach my $s (@scripts) {
            $build_script{$s} = project_config($project, $s, $o);
        }
    } else {
        foreach my $s (@scripts) {
            $build_script{$s} = project_config($project, $s, $options);
        }
    }
    if (!$build_script{$script_name}) {
        $error = "Missing $script_name config";
        goto EXIT;
    }
    @scripts = grep { $build_script{$_} } @scripts;
    push @cfiles, @scripts unless $use_srcdir;
    foreach my $s (@scripts) {
        write_file("$srcdir/$s", $build_script{$s});
        chmod 0700, "$srcdir/$s";
    }
    chdir $srcdir;
    my $res;
    if ($remote_tmp_src && $remote_tmp_dst) {
        foreach my $file (@cfiles) {
            my $cmd = project_config($project, "remote_put", {
                    %$options,
                    put_src => "$srcdir/$file",
                    put_dst => $remote_tmp_src,
                    exec_name => 'put',
                    exec_as_root => 0,
                });
            if (run_script($project, $cmd, sub { system(@_) }) != 0) {
                $error = "Error uploading $file";
                goto EXIT;
            }
        }
        foreach my $s (@scripts) {
            my $cmd = project_config($project, "remote_exec", {
                    %$options,
                    exec_cmd => "cd $remote_tmp_src; ./$s",
                    exec_name => $s,
                    exec_as_root => $scripts_root{$s},
                });
            if (run_script($project, $cmd, sub { system(@_) }) != 0) {
                $error = "Error running $script_name";
                if (project_config($project, 'debug', $options)) {
                    print STDERR $error, "\nOpening debug shell\n";
                    print STDERR "Warning: build files will be removed when you exit this shell.\n";
                    my $cmd = project_config($project, "remote_exec", {
                            %$options,
                            exec_cmd => "cd $remote_tmp_src; PS1='debug-$project\$ ' \${SHELL-/bin/bash}",
                            exec_name => "debug-$s",
                            exec_as_root => $scripts_root{$s},
                            interactive => 1,
                        });
                    run_script($project, $cmd, sub { system(@_) });
                }
                goto EXIT;
            }
        }
        my $cmd = project_config($project, "remote_get", {
                %$options,
                get_src => $remote_tmp_dst,
                get_dst => $dest_dir,
                exec_name => 'get',
                exec_as_root => 0,
            });
        if (run_script($project, $cmd, sub { system(@_) }) != 0) {
            $error = "Error downloading build result";
        }
        run_script($project, project_config($project, "remote_exec", {
                %$options,
                exec_cmd => "rm -Rf $remote_tmp_src $remote_tmp_dst",
                exec_name => 'clean',
                exec_as_root => 0,
            }), \&capture_exec);
    } else {
        foreach my $s (@scripts) {
            my $cmd = $scripts_root{$s} ? project_config($project, 'suexec',
                { suexec_cmd => "$srcdir/$s" }) : "$srcdir/$s";
            if (system($cmd) != 0) {
                $error = "Error running $script_name";
                if (project_config($project, 'debug', $options)) {
                    print STDERR $error, "\nOpening debug shell\n";
                    print STDERR "Warning: build files will be removed when you exit this shell.\n";
                    run_script($project, "PS1='debug-$project\$ ' \$SHELL", sub { system(@_) });
                }
            }
        }
    }
    EXIT:
    if ($remote_tmp_src && $remote_tmp_dst) {
        my $cmd = project_config($project, "remote_finish", $options);
        if ($cmd && (run_script($project, $cmd, sub { system(@_) }) != 0)) {
            $error ||= "Error finishing remote";
        }
    }
    $config->{step} = $old_step;
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
                                . '/rbm-XXXXXX');
        build_pkg($project, {output_dir => $publish_src_dir});
    }
    build_run($project, 'publish', { build_srcdir => $publish_src_dir });
}

1;
# vim: expandtab sw=4
