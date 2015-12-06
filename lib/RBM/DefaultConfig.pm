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

sub git_describe {
    my ($project, $options) = @_;
    my $git_hash = RBM::project_config($project, 'git_hash', $options)
                || RBM::exit_error('No git_hash specified');
    my %res;
    $RBM::config->{projects}{$project}{describe} = {};
    my $old_cwd = getcwd;
    RBM::git_clone_fetch_chdir($project, $options);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'describe', '--long', $git_hash);
    if ($success) {
        @res{qw(tag tag_reach hash)} = $stdout =~ m/^(.+)-(\d+)-g([^-\n]+)$/;
    }
    chdir($old_cwd);
    return $success ? \%res : undef;
}

sub lsb_release {
    my ($project, $options) = @_;
    my $distribution = RBM::project_config($project, 'distribution', $options);
    if ($distribution) {
        my ($id, $release) = split '-', $distribution;
        return { id => $id, release => $release };
    }
    my $res = {};
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('lsb_release', '-irc');
    exit_error("Unknown distribution") unless $success;
    foreach (split "\n", $stdout) {
        $res->{id} = $1 if (m/^Distributor ID:\s+(.+)$/);
        $res->{release} = $1 if (m/^Release:\s+(.+)$/);
        $res->{codename} = $1 if (m/^Codename:\s+(.+)$/);
    }
    return $res;
}

sub get_arch {
    my ($stdout, $stderr, $success, $exit_code) = capture_exec('uname', '-m');
    return "unknown" unless $success;
    chomp $stdout;
    return $stdout;
}

our %default_config = (
    sysconf_file  => '/etc/rbm.conf',
    tmp_dir       => '/tmp',
    projects_dir  => 'projects',
    output_dir    => 'out',
    git_clone_dir => 'git_clones',
    hg_clone_dir  => 'hg_clones',
    fetch         => 'if_needed',
    rpmspec       => '[% SET tmpl = project _ ".spec"; INCLUDE $tmpl -%]',
    build         => '[% INCLUDE build -%]',
    notmpl        => [ qw(projects_dir) ],
    describe      => \&git_describe,
    abbrev_lenght => '12',
    abbrev        => '[%
                         IF c("git_url");
                                exec("git log -1 --abbrev=" _ c("abbrev_lenght") _ " --format=%h " _ c("git_hash"));
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
####
####
####
    pkg_type      => 'build',
    rpm           => '[% c("rpmbuild", { rpmbuild_action => "-ba" }) %]',
    srpm          => '[% c("rpmbuild", { rpmbuild_action => "-bs" }) %]',
####
####
####
    rpmbuild      => <<END,
[% USE date -%]
#!/bin/sh
set -e -x
srcdir=\$(pwd)
cat > '[% project %].spec' << 'RBM_END_RPM_SPEC'
[% c('rpmspec') %]
RBM_END_RPM_SPEC
touch -m -t [% date.format(c('timestamp'), format = '%Y%m%d%H%M') %] [% project %].spec
rpmbuild [% c('rpmbuild_action', {error_if_undef => 1}) %] --define "_topdir \$srcdir" \\
        --define "_sourcedir \$srcdir" \\
        --define '_srcrpmdir [% dest_dir %]' \\
        --define '_rpmdir [% dest_dir %]' \\
        --define '_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' \\
        "\$srcdir/[% project %].spec"
END
####
####
####
    rpm_rel         => <<OPT_END,
[%-
  IF c('pkg_rel').defined;
        GET c('pkg_rel');
  ELSIF c('describe/tag_reach');
        GET '1.' _ c('describe/tag_reach') _ '.g' _ c('describe/hash');
  ELSE;
        GET '1.g' _ c('abbrev');
  END;
-%]
OPT_END
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
        SET gpg_kr = '--keyring ' _ path(c('gpg_keyring'), path(c('gpg_keyring_dir'))) _ ' --no-default-keyring';
    END;
-%]
exec [% c('gpg_bin') %] [% c('gpg_args') %] --with-fingerprint [% gpg_kr %] "\$@"
GPGEND
####
####
####
    debian_create => <<DEBEND,
[%-
    FOREACH f IN c('debian_files');
      GET 'cat > ' _ tmpl(f.name) _ " << 'END_DEBIAN_FILE'\n";
      GET tmpl(f.content);
      GET "\nEND_DEBIAN_FILE\n\n";
    END;
-%]
DEBEND
####
####
####
    deb_src => <<DEBEND,
#!/bin/sh
set -e -x
[% SET tarfile = project _ '-' _ c('version') _ '.tar.' _ c('compress_tar') -%]
tar xvf [% tarfile %]
mv [% tarfile %] [% dest_dir %]/[% project %]_[% c('version') %].orig.tar.[% c('compress_tar') %]
cd [% project %]-[% c('version') %]
builddir=\$(pwd)
mkdir debian debian/source
cd debian
[% c('debian_create') %]
cd [% dest_dir %]
dpkg-source -b "\$builddir"
DEBEND
####
####
####
    deb => <<DEBEND,
#!/bin/sh
set -e -x
[% SET tarfile = project _ '-' _ c('version') _ '.tar.' _ c('compress_tar') -%]
tar xvf [% tarfile %]
mv [% tarfile %] [% project %]_[% c('version') %].orig.tar.[% c('compress_tar') %]
cd [% project %]-[% c('version') %]
builddir=\$(pwd)
mkdir debian debian/source
cd debian
[% c('debian_create') %]
cd ..
ls ..
[% IF c('debsign_keyid');
    pdebuild_sign = '--debsign-k ' _ c('debsign_keyid');
    debuild_sign = '-k' _ c('debsign_keyid');
ELSE;
    pdebuild_sign = '';
    debuild_sign = '-uc -us';
END -%]
[% IF c('use_pbuilder') -%]
pdebuild [% pdebuild_sign %] --buildresult [% dest_dir %]
[% ELSE -%]
debuild [% debuild_sign %]
cd ..
rm -f build
for file in *
do
        if [ -f "\$file" ]
        then
                mv "\$file" [% dest_dir %]
        fi
done
[% END -%]
DEBEND
####
####
####
    debian_revision => <<OPT_END,
[%-
IF c('pkg_rel');
        GET c('pkg_rel').defined;
ELSIF c('describe/tag_reach');
        GET '1.' _ c('describe/tag_reach') _ '~g' _ c('describe/hash');
ELSE;
        GET '1';
END;
-%]
OPT_END
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
    SET cmd = '/bin/sh -c ' _ shell_quote("id \$user >/dev/null 2>&1 || adduser \$user || useradd \$user");
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
docker tag -f [% c('docker_build_image') %] [% c('docker_save_image') %]
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
    SET src_filename = p.0;
    SET src_dir = p.1;
    GET c("docker_remote_exec", { docker_opt => '-v ' _ src_dir _ ':/rbm_copy',
                             exec_as_root => 1,
                             exec_cmd => 'mkdir -p ' _ dst _ '; cp -ar /rbm_copy/' _ src_filename _ ' ' _ dst
					 _ '; chown ' _ c('docker_user') _ ' ' _ dst _ '/' _ src_filename });
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
OPT_END
####
####
####
    lsb_release => \&lsb_release,
    pkg_type =>  sub {
        my ($project, $options) = @_;
        my $distro = RBM::project_config($project, 'lsb_release/id', $options);
        my %pkg_types = qw(
            Fedora   rpm
            CentOS   rpm
            Mageia   rpm
            openSuSe rpm
            Debian   deb
            Ubuntu   deb
        );
        return $pkg_types{$distro};
    },
    install_package => sub {
        my ($project, $options) = @_;
        my $distro = RBM::project_config($project, 'lsb_release/id', $options);
        my $yum = 'rpm -q [% c("pkg_name") %] > /dev/null || yum install -y [% c("pkg_name") %]';
        my $zypper = 'rpm -q [% c("pkg_name") %] > /dev/null || zypper install [% c("pkg_name") %]';
        my $urpmi = 'rpm -q [% c("pkg_name") %] > /dev/null || urpmi [% c("pkg_name") %]';
        my $apt = 'dpkg -s [% c("pkg_name") %] > /dev/null 2>&1 || apt-get install -y [% c("pkg_name") %]';
        my %install = (
            Fedora   => $yum,
            CentOS   => $yum,
            Mageia   => $urpmi,
            openSuSe => $zypper,
            Debian   => $apt,
            Ubuntu   => $apt,
        );
        return $install{$distro};
    },
    urlget => 'wget -O[% shell_quote(dest_dir _ "/" _ c("filename")) %] [% shell_quote(c("URL")) %]',
    sig_ext => [ qw(gpg asc sig) ],
    enable => 1,
    tar    => <<TAR_END,
[%- SET src = c('tar_src', { error_if_undef => 1 }) -%]
find [% src.join(' ') %] -executable -exec chmod 700 {} \\;
find [% src.join(' ') %] ! -executable -exec chmod 600 {} \\;
find [% src.join(' ') %] | sort | \
        tar --no-recursion --owner=root --group=root --mtime=@[% c('timestamp') %] [% c('tar_args', { error_if_undef => 1 }) %] -T -
TAR_END
####
####
####
    zip    => <<ZIP_END,
[%- SET src = c('zip_src', { error_if_undef => 1 }) -%]
find [% src.join(' ') %] -executable -exec chmod 700 {} \\;
find [% src.join(' ') %] ! -executable -exec chmod 600 {} \\;
find [% src.join(' ') %] | sort | \
        zip -q -@ -X [% c('zip_args', { error_if_undef => 1 }) %]
ZIP_END
####
####
####
    arch   => \&get_arch,
    input_files_by_name => sub { RBM::input_files('getfnames', @_); },
    input_files_id => sub { RBM::input_files('input_files_id', @_); },
    steps => {
        srpm => 'rpm',
        'deb-src' => 'deb',
    },
    suexec => 'sudo -- [% c("suexec_cmd") %]',
    hg => 'hg [% c("hg_opt") %]',
);

1;
# vim: expandtab sw=4
