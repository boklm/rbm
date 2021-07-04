package RBM::DefaultConfig;

use strict;
use warnings;

BEGIN {
    require Exporter;
    our @ISA = qw(Exporter);
    our @EXPORT = qw(%default_config);
}

use File::Basename;
use RBM;
use Cwd qw(getcwd);
use IO::CaptureOutput qw(capture_exec);
use File::Temp;
use File::Path qw(make_path);

sub lsb_release {
    my ($project, $options) = @_;
    my $distribution = RBM::project_config($project, 'distribution', $options);
    if ($distribution) {
        my ($id, $release) = split '-', $distribution;
        return { id => $id, release => $release };
    }
    my $res = {};

    if (-f '/usr/bin/sw_vers') {
        # If sw_vers exists, we assume we are on macOS and use it
        my ($stdout, $stderr, $success, $exit_code)
                = capture_exec('/usr/bin/sw_vers', '-productName');
        RBM::exit_error("sw_vers: unknown ProductName")
                unless $success;
        ($res->{id}) = split("\n", $stdout);
        ($stdout, $stderr, $success, $exit_code)
                = capture_exec('/usr/bin/sw_vers', '-productVersion');
        RBM::exit_error("sw_vers: unknown ProductVersion")
                unless $success;
        ($res->{release}) = split("\n", $stdout);
        $res->{codename} = $res->{release};
        return $res;
    }

    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('lsb_release', '-irc');
    if ($success) {
        foreach (split "\n", $stdout) {
            $res->{id} = $1 if (m/^Distributor ID:\s+(.+)$/);
            $res->{release} = $1 if (m/^Release:\s+(.+)$/);
            $res->{codename} = $1 if (m/^Codename:\s+(.+)$/);
        }
        return $res;
    }

    ($stdout, $stderr, $success, $exit_code)
        = capture_exec('uname', '-s');
    RBM::exit_error("Unknown OS") unless $success;
    ($res->{id}) = split("\n", $stdout);
    ($stdout, $stderr, $success, $exit_code)
        = capture_exec('uname', '-r');
    RBM::exit_error("Unknown OS release") unless $success;
    ($res->{release}) = split("\n", $stdout);
    $res->{codename} = $res->{release};
    return $res;
}

sub get_arch {
    my ($stdout, $stderr, $success, $exit_code) = capture_exec('uname', '-m');
    return "unknown" unless $success;
    chomp $stdout;
    return $stdout;
}

sub docker_version {
    my ($stdout, $stderr, $success)
        = capture_exec('docker', 'version', '--format', '{{.Client.Version}}');
    if ($success) {
        chomp $stdout;
        return $stdout;
    }
    ($stdout, $stderr, $success) = capture_exec('docker', 'version');
    RBM::exit_error("Error running 'docker version'") unless $success;
    foreach my $line (split "\n", $stdout) {
        return $1 if ($line =~ m/Client version: (.*)$/);
    }
    RBM::exit_error("Could not find docker version");
}

sub rbm_tmp_dir {
    my ($project, $options) = @_;
    CORE::state $rbm_tmp_dir;
    return $rbm_tmp_dir->dirname if $rbm_tmp_dir;
    my $tmp_dir = RBM::project_config($project, 'tmp_dir', $options)
                  || RBM::exit_error('No tmp_dir specified');
    make_path($tmp_dir);
    $rbm_tmp_dir = File::Temp->newdir(TEMPLATE => 'rbm-XXXXXX',
                                      DIR => $tmp_dir);
    return $rbm_tmp_dir->dirname;
}

our %default_config = (
    sysconf_file  => '/etc/rbm.conf',
    localconf_file=> 'rbm.local.conf',
    tmp_dir       => '[% GET ENV.TMPDIR ? ENV.TMPDIR : "/tmp"; %]',
    rbm_tmp_dir   => \&rbm_tmp_dir,
    projects_dir  => 'projects',
    output_dir    => 'out',
    git_clone_dir => 'git_clones',
    hg_clone_dir  => 'hg_clones',
    fetch         => 'if_needed',
    pkg_type      => 'build',
    build         => '[% INCLUDE build -%]',
    build_log     => '-',
    build_log_append => '1',
    notmpl        => [ qw(projects_dir) ],
    abbrev_length => '12',
    abbrev        => '[%
                         IF c("git_url");
                                exec("git log -1 --abbrev=" _ c("abbrev_length") _ " --format=%h " _ c("git_hash"));
                         ELSE;
                                exec(c("hg") _ " id -i -r " _ c("hg_hash"));
                         END;
                      %]',
    timestamp     => sub {
        my ($project, $options) = @_;
        if (RBM::project_config($project, 'git_url', $options)) {
            my $git_hash = RBM::project_config($project, 'git_hash', $options);
            return RBM::execute($project,
                "git show -s --format=format:%ct ${git_hash}^{commit}", $options);
        } elsif (RBM::project_config($project, 'hg_url', $options)) {
            my $hg = RBM::project_config($project, 'hg', $options);
            my $hg_hash = RBM::project_config($project, 'hg_hash', $options);
            my $changeset = RBM::execute($project,
                "$hg export --noninteractive -r $hg_hash", $options);
            foreach my $line (split "\n", $changeset) {
                return $1 if ($line =~ m/^# Date (\d+) \d+/);
            }
        }
        return '946684800';
    },
    debug         => 0,
    version       => "[%- exit_error('No version specified'); -%]",
####
####
####
    gpg_bin         => 'gpg',
    gpg_args        => '',
    gpg_keyring_dir => '[% config.basedir %]/keyring',
    gpg_wrapper     => <<GPGEND,
#!/bin/sh
export LC_ALL=C
[%
    IF c('gpg_keyring');
        SET gpg_kr = '--keyring ' _ path(c('gpg_keyring'), path(c('gpg_keyring_dir')))
                     _ ' --no-default-keyring --no-auto-check-trustdb --trust-model always';
    END;
-%]
exec [% c('gpg_bin') %] [% c('gpg_args') %] --with-fingerprint [% gpg_kr %] "\$@"
GPGEND
####
####
####
    ssh_remote_exec => <<OPT_END,
[%-
    ssh_user = c('exec_as_root') ? '-l root' : '';
-%]
ssh [% GET c('ssh_options') IF c('ssh_options') %] [% ssh_user %] [% GET '-p ' _ c('ssh_port') IF c('ssh_port') %] [% c('ssh_host') %] [% shell_quote(c('exec_cmd')) -%]
OPT_END
####
####
####
    chroot_remote_exec => <<OPT_END,
[%-
    chroot_user = c('exec_as_root') ? '' : shell_quote(c("chroot_user", { error_if_undef => 1 }));
-%]
sudo -- chroot [% shell_quote(c("chroot_path", { error_if_undef => 1 })) %] su - [% chroot_user %] -c [% shell_quote(c("exec_cmd")) -%]
OPT_END
####
####
####
    remote_exec => <<OPT_END,
[%
    IF c('remote_docker');
        GET c('docker_remote_exec');
        RETURN;
    END;
    IF c('remote_ssh');
        GET c('ssh_remote_exec');
        RETURN;
    END;
    IF c('remote_chroot');
        GET c('chroot_remote_exec');
        RETURN;
    END;
-%]
OPT_END
####
####
####
    remote_get => <<OPT_END,
[%
    IF c('remote_docker');
        GET c('docker_remote_get');
        RETURN;
    END;

    SET src = shell_quote(c('get_src', { error_if_undef => 1 }));
    SET dst = shell_quote(c('get_dst', { error_if_undef => 1 }));
-%]
#!/bin/sh
set -e
mkdir -p [% dst %]
cd [% dst %]
if [% c('remote_exec', { exec_cmd => 'test -f ' _ src }) %]
then
        [% c('remote_exec', { exec_cmd => 'cd \$(dirname ' _ src _ ') && tar -cf - \$(basename ' _ src _ ')' }) %] | tar -xf -
else
        [% c('remote_exec', { exec_cmd => 'cd ' _ src _ ' && tar -cf - .' }) %] | tar -xf -
fi
OPT_END
####
####
####
    remote_put => <<OPT_END,
[%
    IF c('remote_docker');
        GET c('docker_remote_put');
        RETURN;
    END;

    SET src = shell_quote(c('put_src', { error_if_undef => 1 }));
    SET dst = shell_quote(c('put_dst', { error_if_undef => 1 }));
-%]
#!/bin/sh
set -e
if [ -f [% src %] ]
then
        cd \$(dirname [% src %])
        tar -cf - \$(basename [% src %]) | [% c('remote_exec', { exec_cmd => 'mkdir -p ' _ dst _ '&& cd ' _ dst _ '&& tar -xf -' }) %]
else
        cd [% src %]
        tar -cf . | [% c('remote_exec', { exec_cmd => 'mkdir -p' _ dst _ '&& cd ' _ dst _ '&& tar -xf -' }) %]
fi

OPT_END
####
####
####
    remote_start => <<OPT_END,
[%
    IF c('remote_docker');
        GET c('docker_remote_start');
        RETURN;
    END;
-%]
OPT_END
####
####
####
    remote_finish => <<OPT_END,
[%
    IF c('remote_docker');
        GET c('docker_remote_finish');
        RETURN;
    END;
-%]
OPT_END
####
####
####
    docker_version     => \&docker_version,
####
####
####
    docker_build_image => 'rbm-[% sha256(c("build_id")).substr(0, 12) %]',
####
####
####
    docker_remote_start => <<OPT_END,
#!/bin/sh
set -e
ciddir=\$(mktemp -d)
cidfile="\$ciddir/cid"
[%
    SET user=c('docker_user');
    SET cmd = '/bin/sh -c ' _ shell_quote("id \$user >/dev/null 2>&1 || adduser -m \$user || useradd -m \$user");
-%]
docker run --cidfile="\$cidfile" [% c("docker_opt") %] [% shell_quote(c('docker_image', {error_if_undef => 1})) %] [% cmd %]
cid=\$(cat \$cidfile)
rm -rf "\$ciddir"
docker commit \$cid [% c('docker_build_image') %] > /dev/null < /dev/null
docker rm -f \$cid > /dev/null
OPT_END
####
####
####
    docker_remote_finish => <<OPT_END,
#!/bin/sh
set -e
[% IF c('docker_save_image') -%]
docker tag [% IF versioncmp(c('docker_version'), '1.10.0') == -1; GET '-f'; END; %] [% c('docker_build_image') %] [% c('docker_save_image') %]
[% END -%]
docker rmi -f [% c('docker_build_image') %] > /dev/null
OPT_END
####
####
####
    docker_user => 'rbm',
####
####
####
    docker_remote_exec => <<OPT_END,
#!/bin/sh
set -e
ciddir=\$(mktemp -d)
cidfile="\$ciddir/cid"
set +e
docker run [% IF c('interactive') %]-i -t[% END %] \\
       [% IF c('exec_as_root') %]-u=root[%
                ELSE %]-u=[% shell_quote(c('docker_user')) %][% END %] \\
       --cidfile="\$cidfile" [% c("docker_opt") %] [% c('docker_build_image') %] \\
       /bin/sh -c [% shell_quote(c('exec_cmd')) %]
ret=\$?
set -e
cid=\$(cat \$cidfile)
rm -rf "\$ciddir"
docker commit \$cid [% c('docker_build_image') %] > /dev/null < /dev/null
docker rm -f \$cid > /dev/null
test \$ret -eq 0
OPT_END
####
####
####
    docker_remote_put => <<OPT_END,
[%
    SET src = c('put_src', { error_if_undef => 1 });
    SET dst = c('put_dst', { error_if_undef => 1 });
    SET p = fileparse(src);
    SET src_filename = shell_quote(p.0);
    SET src_dir = shell_quote(p.1);
    SET dst = shell_quote(dst);
    GET c("docker_remote_exec", { docker_opt => '-v ' _ src_dir _ ':/rbm_copy',
                             exec_as_root => 1,
                             exec_cmd => 'su ' _ c('docker_user') _ " -c 'mkdir -p " _ dst _ "';"
                                         _ 'cp -ar /rbm_copy/' _ src_filename _ ' ' _ dst
                                         _ '; chown -h ' _ c('docker_user') _ ' ' _ dst _ '/' _ src_filename
                                         _ '; chown ' _ c('docker_user') _ ' ' _ dst });
%]
OPT_END
####
####
####
    uid => $>,
    docker_remote_get => <<OPT_END,
[%
    SET src = c('get_src', { error_if_undef => 1 });
    SET dst = c('get_dst', { error_if_undef => 1 });
-%]
#!/bin/sh
set -e
tmpdir=\$(mktemp -d)
[%
    GET c("docker_remote_exec", { docker_opt => '-v \$tmpdir:/rbm_copy',
                             exec_as_root => 1,
                             exec_cmd => 'cd ' _ src _ '; tar -cf - . | tar -C /rbm_copy -xf -; chown -R ' _ c('uid') _ ' /rbm_copy'});
%]
cd \$tmpdir
tar -cf - . | tar -C [% dst %] --no-same-owner -xf -
cd - > /dev/null
rm -Rf \$tmpdir
OPT_END
####
####
####
    lsb_release => \&lsb_release,
    install_package => sub {
        my ($project, $options) = @_;
        my $distro = RBM::project_config($project, 'lsb_release/id', $options);
        my $release = RBM::project_config($project, 'lsb_release/release', $options);
        my $yum = 'rpm -q [% c("pkg_name") %] > /dev/null || yum install -y [% c("pkg_name") %]';
        my $dnf = 'rpm -q [% c("pkg_name") %] > /dev/null || dnf install -y [% c("pkg_name") %]';
        my $zypper = 'rpm -q [% c("pkg_name") %] > /dev/null || zypper install [% c("pkg_name") %]';
        my $urpmi = 'rpm -q [% c("pkg_name") %] > /dev/null || urpmi [% c("pkg_name") %]';
        my $apt = 'dpkg -s [% c("pkg_name") %] 2> /dev/null | grep -q "^Status: install ok installed\$" || DEBIAN_FRONTEND=noninteractive apt-get install -q -y [% c("pkg_name") %]';
        my %install = (
            Fedora      => $dnf,
            'Fedora-20' => $yum,
            'Fedora-21' => $yum,
            CentOS      => $dnf,
            Mageia      => $urpmi,
            openSuSe    => $zypper,
            Debian      => $apt,
            Ubuntu      => $apt,
        );
        return $yum if "$distro-$release" =~ m/^Centos-[56]\./;
        return $install{"$distro-$release"} if $install{"$distro-$release"};
        return $install{$distro};
    },
    urlget => <<URLGET,
#!/bin/sh
set -e
[%
    IF c("getting_id");
        SET rbm_tmp_dir = '/tmp';
    ELSE;
        SET rbm_tmp_dir = c("rbm_tmp_dir");
    END;
    -%]
tmpfile="\$(mktemp -p [% shell_quote(rbm_tmp_dir) %])"
wget -O"\$tmpfile" [% shell_quote(c("URL")) %]
mv -f "\$tmpfile" [% shell_quote(dest_dir _ "/" _ c("filename")) %]
URLGET
    sig_ext => [ qw(gpg asc sig) ],
    enable => 1,
    gnu_utils => sub {
        my ($project, $options) = @_;
        my $distro = RBM::project_config($project, 'lsb_release/id', $options);
        my %non_gnu = (
            'Mac OS X'  => 1,
            NetBSD      => 1,
            OpenBSD     => 1,
            FreeBSD     => 1,
            DragonFly   => 1,
        );
        return ! $non_gnu{$distro};
    },
    tar    => <<TAR_END,
[%- SET src = c('tar_src', { error_if_undef => 1 }) -%]
find [% src.join(' ') %] [% IF c('gnu_utils') %]-executable[% ELSE %]-perm +0111[% END %] -exec chmod 700 {} \\;
find [% src.join(' ') %] ! [% IF c('gnu_utils') %]-executable[% ELSE %]-perm +0111[% END %] -exec chmod 600 {} \\;
find [% src.join(' ') %] | sort | \
        GZIP="--no-name \${GZIP}" tar --no-recursion [% IF c('gnu_utils') -%]
                --owner=root --group=root --mtime=@[% c('timestamp') %]
                [%- END -%]
                [% c('tar_args', { error_if_undef => 1 }) %] -T -
TAR_END
####
####
####
    zip    => <<ZIP_END,
[%- SET src = c('zip_src', { error_if_undef => 1 }) -%]
[% USE date -%]
find [% src.join(' ') %] -exec touch -m -t [% date.format(c('timestamp'), format = '%Y%m%d%H%M') %] -- {} +
find [% src.join(' ') %] [% IF c('gnu_utils') %]-executable[% ELSE %]-perm +0111[% END %] -exec chmod 700 {} \\;
find [% src.join(' ') %] ! [% IF c('gnu_utils') %]-executable[% ELSE %]-perm +0111[% END %] -exec chmod 600 {} \\;
find [% src.join(' ') %] | sort | \
        zip -q -@ -X [% c('zip_args', { error_if_undef => 1 }) %]
ZIP_END
####
####
####
    arch   => \&get_arch,
    input_files_by_name => sub { RBM::input_files('getfnames', @_); },
    input_files_id => sub { RBM::input_files('input_files_id', @_); },
    input_files_paths => sub { RBM::input_files('getfpaths', @_); },
    link_input_files => '[% IF c("remote_exec") %]1[% END %]',
    steps => {
    },
    suexec => 'sudo -- [% c("suexec_cmd") %]',
    hg => 'hg [% c("hg_opt") %]',
);

1;
# vim: expandtab sw=4
