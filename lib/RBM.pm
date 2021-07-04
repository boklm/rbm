package RBM;

use warnings;
use strict;
use DateTime;
use Path::Tiny;
use Encode qw(encode);
use Cwd qw(getcwd);
use YAML::XS qw(LoadFile);
use Template;
use File::Basename;
use IO::Handle;
use IO::CaptureOutput qw(capture_exec);
use File::Temp;
use File::Copy;
use File::Copy::Recursive qw(fcopy);
use File::Path qw(make_path);
use File::Basename;
use String::ShellQuote;
use Sort::Versions;
use RBM::DefaultConfig;
use Digest::SHA qw(sha256_hex);
use Data::UUID;
use Data::Dump qw(dd pp);
use FindBin;
use feature "state";


BEGIN {
    require Exporter;
    our @ISA = qw(Exporter);
    our @EXPORT = qw(exit_error);
}

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
    $config->{rbmdir} = $FindBin::Bin;
    $config->{step} = 'rbm_init';
    $config->{opt} = {};
    my $pdir = $config->{projects_dir} || $config->{default}{projects_dir};
    foreach my $p (glob rbm_path($pdir) . '/*') {
        next unless -f "$p/config";
        $config->{projects}{basename($p)} = load_config_file("$p/config");
    }
}

sub load_system_config {
    my ($project) = @_;
    my $cfile = project_config($project ? $project : 'undef', 'sysconf_file');
    $config->{system} = -f $cfile ? load_config_file($cfile) : {};
}

sub load_local_config {
    my ($project) = @_;
    my $cfile = project_config($project ? $project : 'undef', 'localconf_file');
    $cfile = rbm_path($cfile);
    $config->{local} = -f $cfile ? load_config_file($cfile) : {};
}

sub find_config_file {
    for (my $dir = getcwd; $dir ne '/'; $dir = dirname($dir)) {
        return "$dir/rbm.conf" if -f "$dir/rbm.conf";
    }
    exit_error("Can't find config file");
}

sub set_default_env {
    %ENV = (%ENV, %{$config->{ENV}}) if ref $config->{ENV} eq 'HASH';
}

sub rbm_path {
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

sub as_array {
    ref $_[0] eq 'ARRAY' ? $_[0] : [ $_[0] ];
}

sub get_target {
    my ($project, $options, $paths, $target) = @_;
    foreach my $path (@$paths) {
        foreach my $step ([ 'steps', $config->{step} ], []) {
            my $z = config_p($config, $project, $options, @$path, @$step,
                             'targets', $target);
            next unless $z;
            return [ $target ] if ref $z eq 'HASH';
            my @z = ref $z eq 'ARRAY' ? (@{$z}) : ($z);
            return [ map { @{get_target($project, $options, $paths, $_)} } @z ];
        }
    }
    return [];
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
    my $as_array = $options->{as_array};
    my %ok_config = ( HASH => 1, CODE => 1 );
    foreach my $path (@_) {
        my $config_path = config_p($config, $project, $options, @$path);
        next unless $ok_config{ref $config_path};
        my @l;
        push @l, config_p($config_path, $project, $options, "override.$name->[0]")
                if @$name == 1;
        if (!$as_array) {
            @l = grep { defined $_ } @l;
            return $l[0] if @l;
        }
        # 1st priority: targets + step matching
        my $config_step_targets = config_p($config_path, $project, $options, @step, 'targets');
        if ($ok_config{ref $config_step_targets}) {
            foreach my $t (@targets) {
                push @l, config_p($config_step_targets, $project, $options, $t, @$name);
                if (!$as_array) {
                    @l = grep { defined $_ } @l;
                    return $l[0] if @l;
                }
            }
        }
        # 2nd priority: step maching
        push @l, config_p($config_path, $project, $options, @step, @$name);
        if (!$as_array) {
            @l = grep { defined $_ } @l;
            return $l[0] if @l;
        }
        # 3rd priority: target matching
        my $config_targets = config_p($config_path, $project, $options, 'targets');
        if ($ok_config{ref $config_targets}) {
            foreach my $t (@targets) {
                push @l, config_p($config_targets, $project, $options, $t, @$name);
                if (!$as_array) {
                    @l = grep { defined $_ } @l;
                    return $l[0] if @l;
                }
            }
        }
        # last priority: no target and no step matching
        push @l, config_p($config_path, $project, $options, @$name);
        if (!$as_array) {
            @l = grep { defined $_ } @l;
            return $l[0] if @l;
        }
        @l = grep { defined $_ } @l;
        push @$res, @l if @l;
    }
    return $as_array ? $res : undef;
}

sub notmpl {
    my ($name, $project) = @_;
    return 1 if $name eq 'notmpl';
    my @n = (@{$config->{default}{notmpl}},
        @{project_config($project, 'notmpl')});
    return grep { $name eq $_ } @n;
}

sub confkey_str {
    ref $_[0] eq 'ARRAY' ? join '/', @{$_[0]} : $_[0];
}

sub project_config {
    my ($project, $name, $options) = @_;
    CORE::state %config_cache;
    my $res;
    my $error_if_undef = $options->{error_if_undef};
    $options = {%$options, error_if_undef => 0} if $options;
    my $cache_id = pp($config->{run})
                        . pp({ %{$config->{opt}}, $options ? %$options : () });
    my $name_str = ref $name eq 'ARRAY' ? join '/', @$name : $name;
    my $step = $config->{step};
    if (exists $config_cache{$project}{$step}{$name_str}{$cache_id}) {
        $res = $config_cache{$project}{$step}{$name_str}{$cache_id};
        goto FINISH;
    }
    $name = [ split '/', $name ] unless ref $name eq 'ARRAY';
    goto FINISH unless @$name;
    my $opt_save = $config->{opt};
    $config->{opt} = { %{$config->{opt}}, %$options } if $options;
    $res = config($project, $name, $options, ['opt', 'norec'], ['opt'],
                        ['run'], ['projects', $project], ['local'], [],
                        ['system'], ['default']);
    if (!$options->{no_tmpl} && defined($res) && !ref $res
        && !notmpl(confkey_str($name), $project)) {
        $res = process_template($project, $res,
            confkey_str($name) eq 'output_dir' ? '.' : undef);
    }
    $config_cache{$project}{$step}{$name_str}{$cache_id} = $res;
    $config->{opt} = $opt_save;
    FINISH:
    if (!defined($res) && $error_if_undef) {
        my $msg = $error_if_undef eq '1' ?
                "Option " . confkey_str($name) . " is undefined"
                : $error_if_undef;
        exit_error($msg);
    }
    return $res;
}

sub project_step_config {
    my ($run_save, $step_save, $origin_step_save) =
                ($config->{run}, $config->{step}, $config->{origin_step});
    $config->{origin_step} = $config->{step};
    $config->{step} = $_[2]->{step} if $_[2]->{step};
    $config->{run} = { target => $_[2]->{target} };
    $config->{run}{target} //= $run_save->{target};
    my $res = project_config(@_);
    ($config->{run}, $config->{step}, $config->{origin_step}) =
                                ($run_save, $step_save, $origin_step_save);
    return $res;
}

sub exit_error {
    print STDERR "Error: ", $_[0], "\n";
    exit (exists $_[1] ? $_[1] : 1);
}

sub set_git_gpg_wrapper {
    my ($project) = @_;
    my $w = project_config($project, 'gpg_wrapper');
    my (undef, $tmp) = File::Temp::tempfile(
                        DIR => project_config($project, 'rbm_tmp_dir'));
    path($tmp)->spew_utf8($w);
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

sub git_get_signed_tagname {
    foreach my $l (split(/\n/, $_[0])) {
        # the tag message is separated from headers by an empty line, so we
        # ignore anything after the first empty line
        return '' unless $l;
        return $1 if $l =~ m/^tag (.*)$/;
    }
    return '';
}

sub git_tag_sign_id {
    my ($project, $tag) = @_;
    my $w = set_git_gpg_wrapper($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'tag', '-v', $tag);
    unset_git_gpg_wrapper($w);
    return undef unless $success;
    return undef unless git_get_signed_tagname($stdout) eq $tag;
    return gpg_get_fingerprint(split /\n/, $stderr);
}

sub file_sign_id {
    my ($project, $options) = @_;
    my (undef, $gpg_wrapper) = File::Temp::tempfile(DIR =>
                                project_config($project, 'rbm_tmp_dir', $options));
    path($gpg_wrapper)->spew_utf8(project_config($project, 'gpg_wrapper', $options));
    chmod 0700, $gpg_wrapper;
    my ($stdout, $stderr, $success, $exit_code) =
        capture_exec($gpg_wrapper, '--verify',
            project_config($project, 'filename_sig', $options),
            project_config($project, 'filename_data', $options));
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

sub git_need_fetch {
    my ($project, $options) = @_;
    return 0 if $config->{projects}{$project}{fetched};
    my $fetch = project_config($project, 'fetch', $options);
    if ($fetch eq 'if_needed') {
        my $git_hash = project_config($project, 'git_hash', $options)
                || exit_error "No git_hash specified for project $project";
        my (undef, undef, $success) = capture_exec('git', 'rev-parse',
                                        '--verify', "$git_hash^{commit}");
        return !$success;
    }
    return $fetch;
}

sub git_clone_fetch_chdir {
    my ($project, $options) = @_;
    my $clonedir = create_dir(rbm_path(project_config($project,
                                'git_clone_dir', $options)));
    my $git_url = project_config($project, 'git_url', $options)
                || exit_error "git_url is undefined";
    my @clone_submod = ();
    my @fetch_submod = ();
    if (project_config($project, 'git_submodule', $options)) {
        @clone_submod = ('--recurse-submodules');
        @fetch_submod = ('--recurse-submodules=on-demand');
    }
    if (!chdir rbm_path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        if (system('git', 'clone', @clone_submod, $git_url, $project) != 0) {
            exit_error "Error cloning $git_url";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    if (git_need_fetch($project, $options)) {
        system('git', 'remote', 'set-url', 'origin', $git_url) == 0
                || exit_error "Error setting git remote";
        my (undef, undef, $success) = capture_exec('git', 'rev-parse', '--verify', 'HEAD');
        if ($success) {
            system('git', 'checkout', '-q', '--detach') == 0
                || exit_error "Error running git checkout --detach";
        }
        system('git', 'fetch', @fetch_submod, 'origin',
                                '+refs/heads/*:refs/heads/*') == 0
                || exit_error "Error fetching git repository";
        system('git', 'fetch', @fetch_submod, 'origin',
                                '+refs/tags/*:refs/tags/*') == 0
                || exit_error "Error fetching git repository";
        $config->{projects}{$project}{fetched} = 1;
    }
}

sub hg_need_fetch {
    my ($project, $options) = @_;
    return 0 if $config->{projects}{$project}{fetched};
    my $fetch = project_config($project, 'fetch', $options);
    if ($fetch eq 'if_needed') {
        my $hg_hash = project_config($project, 'hg_hash', $options)
                || exit_error "No hg_hash specified for project $project";
        my (undef, undef, $success) = capture_exec('hg', 'export', $hg_hash);
        return !$success;
    }
    return $fetch;
}

sub hg_clone_fetch_chdir {
    my ($project, $options) = @_;
    my $hg = project_config($project, 'hg', $options);
    my $clonedir = create_dir(rbm_path(project_config($project,
                                'hg_clone_dir', $options)));
    my $hg_url = shell_quote(project_config($project, 'hg_url', $options))
                || exit_error "hg_url is undefined";
    my $sq_project = shell_quote($project);
    if (!chdir rbm_path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        if (system("$hg clone -q $hg_url $sq_project") != 0) {
            exit_error "Error cloning $hg_url";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    if (hg_need_fetch($project, $options)) {
        system("$hg pull -q $hg_url") == 0
                || exit_error "Error pulling changes from $hg_url";
    }
}

sub run_script {
    my ($project, $cmd, $f) = @_;
    $f //= \&capture_exec;
    my @res;
    local $ENV{TMPDIR} = project_config($project, 'rbm_tmp_dir');
    if ($cmd =~ m/^#/) {
        my (undef, $tmp) = File::Temp::tempfile(DIR => $ENV{TMPDIR});
        path($tmp)->spew_utf8($cmd);
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
    CORE::state %cache;
    my $res_name;
    my $old_cwd = getcwd;
    if (project_config($project, 'git_url', $options)) {
        my $git_hash = project_config($project, 'git_hash', $options)
                || exit_error "No git_hash specified for project $project";
        $res_name = "git-$project-/-$git_hash-/-$cmd";
        return $cache{$res_name} if exists $cache{$res_name};
        git_clone_fetch_chdir($project, $options);
        my ($stdout, $stderr, $success, $exit_code)
                = capture_exec('git', 'checkout', $git_hash);
        exit_error "Cannot checkout $git_hash:\n$stderr" unless $success;
        if (project_config($project, 'git_submodule', $options)) {
            foreach my $action (qw(init sync update)) {
                ($stdout, $stderr, $success, $exit_code)
                    = capture_exec('git', 'submodule', $action);
                exit_error "Error running git submodule $action\n$stderr"
                    unless $success;
            }
        }
    } elsif (project_config($project, 'hg_url', $options)) {
        my $hg_hash = project_config($project, 'hg_hash', $options)
                || exit_error "No hg_hash specified for project $project";
        $res_name = "hg-$project-/-$hg_hash-/-$cmd";
        return $cache{$res_name} if exists $cache{$res_name};
        hg_clone_fetch_chdir($project, $options);
        my ($stdout, $stderr, $success, $exit_code)
                = capture_exec('hg', 'update', '-C', $hg_hash);
        exit_error "Cannot checkout $hg_hash:\n$stderr" unless $success;
    }
    my ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
    chdir($old_cwd);
    chomp $stdout;
    $cache{$res_name} = $success ? $stdout : undef;
    return $cache{$res_name};
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
    $dest_dir //= create_dir(rbm_path(project_config($project, 'output_dir')));
    valid_project($project);
    my $old_cwd = getcwd;
    my $commit_hash;
    if (project_config($project, 'git_url', $options)) {
        $commit_hash = project_config($project, 'git_hash', $options)
                || exit_error "No git_hash specified for project $project";
        git_clone_fetch_chdir($project);
    } elsif (project_config($project, 'hg_url', $options)) {
        $commit_hash = project_config($project, 'hg_hash', $options)
                || exit_error "No hg_hash specified for project $project";
        hg_clone_fetch_chdir($project);
    } else {
        return undef;
    }

    my $version = project_config($project, 'version', $options);
    if (my $tag_gpg_id = gpg_id(project_config($project, 'tag_gpg_id', $options))) {
        my $id = git_tag_sign_id($project, $commit_hash) ||
                exit_error "$commit_hash is not a signed tag";
        if (!valid_id($id, $tag_gpg_id)) {
            exit_error "Tag $commit_hash is not signed with a valid key";
        }
        print "Tag $commit_hash is signed with key $id\n";
    }
    if (my $commit_gpg_id = gpg_id(project_config($project, 'commit_gpg_id',
                $options))) {
        my $id = git_commit_sign_id($project, $commit_hash) ||
                exit_error "$commit_hash is not a signed commit";
        if (!valid_id($id, $commit_gpg_id)) {
            exit_error "Commit $commit_hash is not signed with a valid key";
        }
        print "Commit $commit_hash is signed with key $id\n";
    }
    my $tar_file = "$project-$version.tar";
    if (project_config($project, 'git_url', $options)) {
        system('git', 'archive', "--prefix=$project-$version/",
            "--output=$dest_dir/$tar_file", $commit_hash) == 0
                || exit_error 'Error running git archive.';
        if (project_config($project, 'git_submodule', $options)) {
            my $tmpdir = File::Temp->newdir(
                project_config($project, 'rbm_tmp_dir', $options) . '/rbm-XXXXX');
            my ($stdout, $stderr, $success, $exit_code)
                = capture_exec('git', 'checkout', $commit_hash);
            exit_error "Cannot checkout $commit_hash: $stderr" unless $success;
            foreach my $action (qw(init sync update)) {
                ($stdout, $stderr, $success, $exit_code)
                    = capture_exec('git', 'submodule', $action);
                exit_error "Error running git submodule $action\n$stderr"
                    unless $success;
            }
            ($stdout, $stderr, $success, $exit_code)
                = capture_exec('git', 'submodule', 'foreach',
                    "git archive --prefix=$project-$version/\$path/"
                    . " --output=$tmpdir/submodule.tar \$sha1;"
                    . "tar -Af \"$dest_dir/$tar_file\" $tmpdir/submodule.tar");
            exit_error 'Error running git archive on submodules.' unless $success;
        }
    } else {
        system('hg', 'archive', '-r', $commit_hash, '-t', 'tar',
            '--prefix', "$project-$version", "$dest_dir/$tar_file") == 0
                || exit_error 'Error running hg archive.';
    }
    my %compress = (
        xz  => ['xz', '-f'],
        gz  => ['gzip', '--no-name', '-f'],
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

sub sha256file {
    CORE::state %res;
    my $f = rbm_path(shift);
    my $opt = shift;
    if (ref $opt eq 'HASH' && $opt->{remove_cache}) {
        delete $res{$f};
        return;
    }
    return $res{$f} if exists $res{$f};
    return $res{$f} = -f $f ? sha256_hex(path($f)->slurp_raw) : '';
}

sub process_template_opt {
    my ($project, $tmpl, $opt, $dest_dir) = @_;
    my $save_opt = $config->{opt};
    $config->{opt} = {%{$config->{opt}}, %$opt} if $opt;
    my $res = process_template($project, $tmpl, $dest_dir);
    $config->{opt} = $save_opt;
    return $res;
}

sub process_template {
    my ($project, $tmpl, $dest_dir) = @_;
    return undef unless defined $tmpl;
    exit_error "Can't process template on a hash" if ref $tmpl eq 'HASH';
    if (ref $tmpl eq 'ARRAY') {
        my $res = [];
        foreach my $t (@$tmpl) {
            push @$res, process_template($project, $t, $dest_dir);
        }
        return $res;
    }
    $dest_dir //= rbm_path(project_config($project, 'output_dir'));
    my $projects_dir = rbm_path(project_config($project, 'projects_dir'));
    my $template = Template->new(
        ENCODING        => 'utf8',
        INCLUDE_PATH    => "$projects_dir/$project:$projects_dir/common",
    );
    my $vars = {
        config     => $config,
        project    => $project,
        p          => $config->{projects}{$project},
        c          => sub { project_config($project, @_) },
        pc         => sub {
            my @args = @_;
            $args[2] = { $_[2] ? %{$_[2]} : (), origin_project => $project };
            project_step_config(@args);
        },
        dest_dir   => $dest_dir,
        exit_error => \&exit_error,
        exec       => sub { execute($project, @_) },
        path       => \&rbm_path,
        tmpl       => sub { process_template($project, $_[0], $dest_dir) },
        shell_quote => \&shell_quote,
        versioncmp  => \&versioncmp,
        sha256      => sub {
            return sha256_hex(encode("utf8", $_[0]));
        },
        sha256file  => \&sha256file,
        fileparse   => \&fileparse,
        ENV         => \%ENV,
    };
    my $output;
    $template->process(\$tmpl, $vars, \$output, binmode => ':utf8')
                    || exit_error "Template Error:\n" . $template->error;
    return $output;
}

sub projectslist {
    keys %{$config->{projects}};
}

sub copy_files {
    my ($project, $dest_dir) = @_;
    my @r;
    my $copy_files = project_config($project, 'copy_files');
    return unless $copy_files;
    my $proj_dir = rbm_path(project_config($project, 'projects_dir'));
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
    return map { -e "$_/$filename" ? "$_/$filename" : () } @dir;
}

sub input_file_need_dl {
    my ($input_file, $t, $fname, $action) = @_;
    return undef if $action eq 'getfpaths';
    if ($fname
        && $input_file->{sha256sum}
        && $t->('sha256sum') ne sha256file($fname)) {
        sha256file($fname, { remove_cache => 1 });
        $fname = undef;
    }
    if ($action eq 'input_files_id') {
        return undef if $input_file->{input_file_id};
        return undef if $input_file->{sha256sum};
        return undef if $input_file->{exec};
        return undef if $fname;
        return 1 if $input_file->{URL};
        return 1 if $input_file->{content};
        return undef;
    }
    return $t->('refresh_input') if $fname;
    return 1;
}

sub input_file_id_hash {
    my ($fname, $filename) = @_;
    return $filename . ':' . sha256file($fname) if -f $fname;
    return $filename . ':' . sha256file(readlink $fname) if -l $fname;
    my @subdirs = sort(map { $_->basename } path($fname)->children);
    my @hashes = map { input_file_id_hash("$fname/$_", "$filename/$_") } @subdirs;
    return join("\n", @hashes);
}

sub input_file_id {
    my ($input_file, $t, $fname, $filename) = @_;
    return $t->('input_file_id') if $input_file->{input_file_id};
    return $input_file->{project} . ':' . $filename if $input_file->{project};
    return $filename . ':' . $t->('sha256sum') if $input_file->{sha256sum};
    my $opts = { norec => { output_dir => '/out', getting_id => 1, }};
    return $filename . ':' . sha256_hex($t->('exec', $opts))
                if $input_file->{exec};
    return input_file_id_hash($fname, $filename);
}

sub recursive_copy {
    my ($fname, $name, $dest_dir, $action) = @_;
    if (-f $fname && $action eq 'link') {
        return ($name) if link $fname, "$dest_dir/$name";
    }
    if (-f $fname || -l $fname) {
        fcopy($fname, "$dest_dir/$name");
        return ($name);
    }
    my @copied;
    mkdir "$dest_dir/$name";
    foreach my $f (map { $_->basename } path($fname)->children) {
        push @copied, recursive_copy("$fname/$f", "$name/$f", $dest_dir, $action);
    }
    return @copied;
}

sub input_files {
    my ($action, $project, $options, $dest_dir) = @_;
    my @res_copy;
    my %res_getfnames;
    my @res_getfpaths;
    my $getfnames_noname = 0;
    my $input_files_id = '';
    $options = {$options ? %$options : ()};
    $options->{norec} = {};
    my $input_files = project_config($project, 'input_files', $options);
    goto RETURN_RES unless $input_files;
    my $proj_dir = rbm_path(project_config($project, 'projects_dir', $options));
    my $src_dir = "$proj_dir/$project";
    my $common_dir = "$proj_dir/common";
    my $old_cwd = getcwd;
    chdir $src_dir || exit_error "cannot chdir to $src_dir";
    foreach my $input_file_alias (@$input_files) {
        my $input_file = $input_file_alias;
        if (!ref $input_file) {
            $input_file = project_config($project,
                process_template_opt($project, $input_file, $options), $options);
        }
        next unless $input_file;
        my $t = sub {
            project_config($project, $_[0], {$options ? %$options : (),
                    %$input_file, $_[1] ? %{$_[1]} : ()});
        };
        if ($input_file->{enable} && !$t->('enable')) {
            next;
        }
        if ($input_file->{target} || $input_file->{target_append}
                                  || $input_file->{target_prepend}) {
            $input_file = { %$input_file };
            foreach my $t (qw/target target_append target_prepend/) {
                if ($input_file->{$t} && ref $input_file->{$t} ne 'ARRAY') {
                    exit_error("$t should be an ARRAY:\n" . pp($input_file));
                }
            }
            if ($input_file->{target}) {
                $input_file->{target} = process_template_opt($project,
                                            $input_file->{target}, $options);
            } else {
                $input_file->{target} = $config->{run}{target};
            }
            if ($input_file->{target_prepend}) {
                $input_file->{target} = [ @{ process_template_opt($project,
                                               $input_file->{target_prepend},
                                               $options) },
                                          @{$input_file->{target}} ];
            }
            if ($input_file->{target_append}) {
                $input_file->{target} = [ @{$input_file->{target}},
                                          @{ process_template_opt($project,
                                               $input_file->{target_append},
                                               $options) } ];
            }
        }
        if ($action eq 'getfnames') {
            my $getfnames_name;
            if ($input_file->{name}) {
                $getfnames_name = $t->('name');
            } else {
                $getfnames_name = "noname_$getfnames_noname";
                $getfnames_noname++;
            }
            $res_getfnames{$getfnames_name} = sub {
                my ($project, $options) = @_;
                $options //= {};
                if ($input_file->{project}) {
                    $options = {%$options};
                    $options->{origin_project} = $project;
                }
                my $t = sub {
                    RBM::project_config($project, $_[0], { %$options, %$input_file })
                };
                return $t->('filename') if $input_file->{filename};
                my $url = $t->('URL');
                return basename($url) if $url;
                return RBM::project_step_config($t->('project'), 'filename',
                        {%$options, step => $t->('pkg_type'), %$input_file})
                    if $input_file->{project};
                return undef;
            };
            next;
        }
        my $proj_out_dir;
        if ($input_file->{project}) {
            $proj_out_dir = rbm_path(project_step_config($t->('project'), 'output_dir',
                    { %$options, step => $t->('pkg_type'),
                        origin_project => $project, %$input_file }));
        } else {
            $proj_out_dir = rbm_path(project_config($project, 'output_dir',
                    { %$options, %$input_file }));
        }
        create_dir($proj_out_dir);
        my $url = $t->('URL');
        my $name = $input_file->{filename} ? $t->('filename') :
                   $url ? basename($url) :
                   undef;
        $name //= project_step_config($t->('project'), 'filename',
            {%$options, step => $t->('pkg_type'),
                origin_project => $project, %$input_file})
                if $input_file->{project};
        exit_error("Missing filename:\n" . pp($input_file)) unless $name;
        my ($fname) = file_in_dir($name, $src_dir, $proj_out_dir, $common_dir);
        my $file_gpg_id = gpg_id($t->('file_gpg_id'));
        if (input_file_need_dl($input_file, $t, $fname, $action)) {
            if ($t->('content')) {
                path("$proj_out_dir/$name")->spew_utf8($t->('content'));
            } elsif ($t->('URL')) {
                urlget($project, {%$options, %$input_file, filename => $name}, 1);
            } elsif ($t->('exec')) {
                my $exec_script = project_config($project, 'exec',
                    { $options ? %$options : (), %$input_file });
                if (run_script($project, $exec_script,
                        sub { system(@_) }) != 0) {
                    exit_error "Error creating $name";
                }
            } elsif ($input_file->{project} && $t->('project')) {
                my $p = $t->('project');
                print "Building project $p - $name\n";
                my $run_save = $config->{run};
                $config->{run} = { target => $input_file->{target} };
                $config->{run}{target} //= $run_save->{target};
                build_pkg($p, {%$options, origin_project => $project,
                               %$input_file});
                $config->{run} = $run_save;
                print "Finished build of project $p - $name\n";
            } else {
                dd $input_file;
                exit_error "Missing file $name";
            }
            ($fname) = file_in_dir($name, $src_dir, $proj_out_dir, $common_dir);
            exit_error "Error getting file $name" unless $fname;
        }
        if ($action eq 'input_files_id') {
            $input_files_id .= input_file_id($input_file, $t, $fname, $name);
            $input_files_id .= "\n";
            next;
        }
        if ($action eq 'getfpaths') {
            push @res_getfpaths, $fname if $fname;
            if ($file_gpg_id && $fname) {
                my $sig_ext = $t->('sig_ext');
                $sig_ext = ref $sig_ext eq 'ARRAY' ? $sig_ext : [ $sig_ext ];
                foreach my $s (@$sig_ext) {
                    if (-f "$fname.$s") {
                        push @res_getfpaths, "$fname.$s";
                        last;
                    }
                }
            }
            if ($input_file->{project} && $t->('project')) {
                my $r = RBM::project_step_config($t->('project'), 'input_files_paths',
                            {%$options, step => $t->('pkg_type'),
                                origin_project => $project, %$input_file});
                push @res_getfpaths, @$r if @$r;
            }
            next;
        }
        exit_error "Missing file $name" unless $fname;
        if ($t->('sha256sum')
            && $t->('sha256sum') ne sha256file($fname)) {
            exit_error "Can't have sha256sum on directory: $fname" if -d $fname;
            exit_error "Wrong sha256sum for $fname.\n" .
                       "Expected sha256sum: " . $t->('sha256sum');
        }
        if ($file_gpg_id) {
            exit_error "Can't have gpg sig on directory: $fname" if -d $fname;
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
                    my $f = { %$options, %$input_file,
                        'override.URL' => "$url.$s", filename => "$name.$s" };
                    if (urlget($project, $f, 0)) {
                        $sig_file = "$fname.$s";
                        last;
                    }
                }
            }
            exit_error "No signature file for $name" unless $sig_file;
            my $id = file_sign_id($project, { %$input_file,
                    filename_data => $fname, filename_sig => $sig_file });
            print "File $name is signed with id $id\n" if $id;
            if (!$id || !valid_id($id, $file_gpg_id)) {
                exit_error "File $name is not signed with a valid key";
            }
        }
        my $file_type = -d $fname ? 'directory' : 'file';
        print "Using $file_type $fname\n";
        mkdir dirname("$dest_dir/$name");
        push @res_copy, recursive_copy($fname, $name, $dest_dir, $action);
    }
    chdir $old_cwd;
    RETURN_RES:
    return sha256_hex($input_files_id) if $action eq 'input_files_id';
    return @res_copy if ($action eq 'copy' || $action eq 'link');
    return \%res_getfnames if $action eq 'getfnames';
    return \@res_getfpaths if $action eq 'getfpaths';
}

sub system_log {
    my ($log_file, @args) = @_;
    return system(@args) if $log_file eq '-';
    if (my $pid = fork) {
        waitpid($pid, 0);
        return ${^CHILD_ERROR_NATIVE};
    }
    exit_error "Could not open $log_file" unless open(STDOUT, '>>', $log_file);
    open(STDERR, '>&', *STDOUT);
    exec(@args);
}

sub log_start_time {
    my ($log_file, $script_name) = @_;
    my $start_time = DateTime->now;
    my $start_time_txt = $start_time->ymd . ' ' . $start_time->hms;
    path($log_file)->append_utf8("Starting build (script: $script_name): $start_time_txt\n");
    return $start_time;
}

sub log_end_time {
    my ($log_file, $script_name, $start_time) = @_;
    my $end_time = DateTime->now;
    my $end_time_txt = $end_time->ymd . ' ' . $end_time->hms;
    path($log_file)->append_utf8("Finishing build (script: $script_name): $end_time_txt\n");
    my $build_time = $end_time - $start_time;
    my ($bth, $btm, $bts) = $build_time->in_units('hours', 'minutes', 'seconds');
    path($log_file)->append_utf8("Build time: $bth hours $btm minutes and $bts seconds\n");
}

sub build_run {
    my ($project, $script_name, $options) = @_;
    my ($old_step, $old_origin_step) = ($config->{step}, $config->{origin_step});
    $config->{origin_step} = $config->{step};
    $config->{step} = $script_name;
    $options //= {};
    my $error;
    my $dest_dir = create_dir(rbm_path(project_config($project, 'output_dir', $options)));
    valid_project($project);
    $options = { %$options, build_id => Data::UUID->new->create_str };
    my $old_cwd = getcwd;
    my $tmpdir = File::Temp->newdir(project_config($project, 'rbm_tmp_dir', $options)
                                . '/rbm-XXXXX');
    my $srcdir = $tmpdir->dirname;
    my @cfiles;
    push @cfiles, copy_files($project, $srcdir);
    my $if_action = project_config($project, 'link_input_files', $options) ?
                                'link' : 'copy';
    push @cfiles, input_files($if_action, $project, $options, $srcdir);
    my $tarfile = maketar($project, $options, $srcdir);
    push @cfiles, $tarfile if $tarfile;
    my ($remote_tmp_src, $remote_tmp_dst, %build_script);
    my @scripts = ('pre', $script_name, 'post');
    my %scripts_root = ( pre => 1, post => 1);
    if (project_config($project, "remote_exec", $options)) {
        my $cmd = project_config($project, "remote_start", {
                %$options,
                remote_srcdir => $srcdir,
            });
        if ($cmd) {
            my ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
            if (!$success) {
                $error = "Error starting remote:\n$stdout\n$stderr";
                goto EXIT;
            }
        }
        foreach my $remote_tmp ($remote_tmp_src, $remote_tmp_dst) {
            $cmd = project_config($project, "remote_exec", {
                    %$options,
                    exec_cmd => project_config($project,
                        "remote_mktemp", $options) || 'mktemp -d -p /var/tmp',
                    exec_name => 'mktemp',
                    exec_as_root => 0,
                });
            my ($stdout, $stderr, $success, $exit_code)
                = run_script($project, $cmd, \&capture_exec);
            if (!$success) {
                $error = "Error connecting to remote:\n$stdout\n$stderr";
                goto EXIT;
            }
            $remote_tmp = (split(/\r?\n/, $stdout))[0];
        }
        my $o = {
            %$options,
            norec => { output_dir => $remote_tmp_dst },
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
    push @cfiles, @scripts;
    foreach my $s (@scripts) {
        path("$srcdir/$s")->spew_utf8($build_script{$s});
        chmod 0700, "$srcdir/$s";
    }
    my $build_log = project_config($project, "build_log", $options);
    if ($build_log ne '-') {
        my $append = project_config($project, "build_log_append", $options);
        $build_log = rbm_path($build_log);
        unlink $build_log unless $append;
        make_path(dirname($build_log));
        if (!-f $build_log) {
            my $now = localtime;
            path($build_log)->append_utf8("Opening log file: $now\n");
        }
        print "Build log: $build_log\n";
    }
    chdir $srcdir;
    my $res;
    if ($remote_tmp_src && $remote_tmp_dst) {
        foreach my $file (@cfiles) {
            my $cmd = project_config($project, "remote_put", {
                    %$options,
                    put_src => "$srcdir/$file",
                    put_dst => $remote_tmp_src . '/' . dirname($file),
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
            my $start_time = log_start_time($build_log, $s) if $build_log ne '-';
            my $res = run_script($project, $cmd, sub { system_log($build_log, @_) });
            log_end_time($build_log, $s, $start_time) if $build_log ne '-';
            if ($res != 0) {
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
            my $start_time = log_start_time($build_log, $s) if $build_log ne '-';
            my $res = run_script($project, $cmd, sub { system_log($build_log, @_) });
            log_end_time($build_log, $s, $start_time) if $build_log ne '-';
            if ($res != 0) {
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
    if (project_config($project, "remote_exec", $options)) {
        my $cmd = project_config($project, "remote_finish", $options);
        if ($cmd && (run_script($project, $cmd, sub { system(@_) }) != 0)) {
            $error ||= "Error finishing remote";
        }
    }
    ($config->{step}, $config->{origin_step}) = ($old_step, $old_origin_step);
    chdir $old_cwd;
    exit_error $error if $error;
}

sub build_pkg {
    my ($project, $options) = @_;
    build_run($project, project_config($project, 'pkg_type', $options), $options);
}

1;
# vim: expandtab sw=4
