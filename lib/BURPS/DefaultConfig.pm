package BURPS::DefaultConfig;

use strict;
use warnings;

BEGIN {
    require Exporter;
    our @ISA = qw(Exporter);
    our @EXPORT = qw(%default_config);
}

use BURPS;
use Cwd qw(getcwd);
use IO::CaptureOutput qw(capture_exec);

sub git_describe {
    my ($project, $options) = @_;
    my $git_hash = BURPS::project_config($project, 'git_hash', $options)
                || BURPS::exit_error('No git_hash specified');
    my %res;
    $BURPS::config->{projects}{$project}{describe} = {};
    my $old_cwd = getcwd;
    BURPS::git_clone_fetch_chdir($project, $options);
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
    $options //= {};
    my $distribution = BURPS::project_config($project, 'distribution',
                                        { %$options, no_distro => 1 });
    if ($distribution) {
        my @distributions = map { @$_ }
                @{BURPS::project_config($project, 'distributions',
                        { %$options, as_array => 1, no_distro => 1 })};
        my ($id, $release) = split '-', $distribution;
        foreach my $d (@distributions) {
            if ($id eq $d->{lsb_release}{id} && $release
                        && $d->{lsb_release}{release}
                        && $release eq $d->{lsb_release}{release}) {
                return {
                    id => $id,
                    release => $release,
                    codename => $d->{lsb_release}{codename},
                };
            }
        }
        return { id => $id, release => $release };
    }
    my $res = {};
    my $u = "Unknown distribution. Check burps_distributions(7) man page.";
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('lsb_release', '-irc');
    exit_error $u unless $success;
    foreach (split "\n", $stdout) {
        $res->{id} = $1 if (m/^Distributor ID:\s+(.+)$/);
        $res->{release} = $1 if (m/^Release:\s+(.+)$/);
        $res->{codename} = $1 if (m/^Codename:\s+(.+)$/);
    }
    return $res;
}

sub lsb_release_cache {
    return $BURPS::config->{default}{lsb_release} = lsb_release(@_);
}

sub get_arch {
    my ($stdout, $stderr, $success, $exit_code) = capture_exec('uname', '-m');
    return "unknown" unless $success;
    chomp $stdout;
    return $stdout;
}

sub input_files_by_name {
    my ($project, $options) = @_;
    $options //= {};
    my $input_files = BURPS::project_config($project, 'input_files', $options);
    return {} unless ref $input_files eq 'ARRAY';
    my $res = {};
    foreach my $input_file (@$input_files) {
        next unless $input_file->{name};
        my $name = BURPS::project_config($project, 'name', { %$options, %$input_file });
        $res->{$name} = sub {
            my ($project, $options) = @_;
            $options //= {};
            return BURPS::project_config($project, 'filename', { %$options, %$input_file });
        };
    }
    return $res;
}

our %default_config = (
    sysconf_file  => '/etc/burps.conf',
    tmp_dir       => '/tmp',
    projects_dir  => 'projects',
    output_dir    => 'out',
    git_clone_dir => 'git_clones',
    fetch         => 1,
    rpmspec       => '[% SET tmpl = project _ ".spec"; INCLUDE $tmpl -%]',
    build         => '[% INCLUDE build -%]',
    notmpl        => [ qw(projects_dir) ],
    describe      => \&git_describe,
    abbrev_lenght => '12',
    abbrev        => '[% exec("git log -1 --abbrev=" _ c("abbrev_lenght") _ " --format=%h " _ c("git_hash")) %]',
    timestamp     => '[% exec("git show -s --format=format:%ct " _ c("git_hash") _ "^{commit}") %]',
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
    pkg_type      => 'build',
    rpm           => '[% c("rpmbuild", { rpmbuild_action => "-ba" }) %]',
    srpm          => '[% c("rpmbuild", { rpmbuild_action => "-bs" }) %]',
    rpmbuild      => <<END,
[% USE date -%]
#!/bin/sh
set -e -x
srcdir=\$(pwd)
cat > '[% project %].spec' << 'BURPS_END_RPM_SPEC'
[% c('rpmspec') %]
BURPS_END_RPM_SPEC
touch -m -t [% date.format(c('timestamp'), format = '%Y%m%d%H%M') %] [% project %].spec
rpmbuild [% c('rpmbuild_action', {error_if_undef => 1}) %] --define "_topdir \$srcdir" \\
        --define "_sourcedir \$srcdir" \\
        --define '_srcrpmdir [% dest_dir %]' \\
        --define '_rpmdir [% dest_dir %]' \\
        --define '_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' \\
        "\$srcdir/[% project %].spec"
END
    rpm_rel         => <<OPT_END,
[%-
  IF c('pkg_rel').defined;
        GET c('pkg_rel');
  ELSIF c('describe/tag_reach');
        GET '1.' _ c('describe/tag_reach') _ '.g' _ c('describe/hash');
  ELSE;
        GET '1';
  END;
-%]
OPT_END
    gpg_bin         => 'gpg',
    gpg_args        => '',
    gpg_keyring_dir => '[% config.basedir %]/keyring',
    gpg_wrapper     => <<GPGEND,
#!/bin/sh
[%
    IF c('gpg_keyring');
        SET gpg_kr = '--keyring ' _ path(c('gpg_keyring'), path(c('gpg_keyring_dir'))) _ ' --no-default-keyring';
    END;
-%]
exec [% c('gpg_bin') %] [% c('gpg_args') %] --with-fingerprint [% gpg_kr %] "\$@"
GPGEND
    debian_create => <<DEBEND,
[%-
    FOREACH f IN c('debian_files');
      GET 'cat > ' _ tmpl(f.name) _ " << 'END_DEBIAN_FILE'\n";
      GET tmpl(f.content);
      GET "\nEND_DEBIAN_FILE\n\n";
    END;
-%]
DEBEND
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
    remote_ssh => {
        exec => <<OPT_END,
ssh [% GET c('ssh_options') IF c('ssh_options') %] [% GET '-p ' _ c('ssh_port') IF c('ssh_port') %] [% c('ssh_host') %] [% shell_quote(c('exec_cmd')) -%]
OPT_END
    },
    remote_chroot => {
        exec => 'sudo chroot [% shell_quote(c("chroot_path", { error_if_undef => 1 })) %] su - [% shell_quote(c("chroot_user", { error_if_undef => 1 })) %] -c [% shell_quote(c("exec_cmd")) %]',
    },
    remote_get => <<OPT_END,
[%
    SET src = shell_quote(c('get_src', { error_if_undef => 1 }));
    SET dst = shell_quote(c('get_dst', { error_if_undef => 1 }));
-%]
#!/bin/sh
set -e
mkdir -p [% dst %]
cd [% dst %]
if [% c('remote_chroot/exec', { exec_cmd => 'test -f ' _ src }) %]
then
        [% c('remote_chroot/exec', { exec_cmd => 'cd \$(dirname ' _ src _ ') && tar -cf - \$(basename ' _ src _ ')' }) %] | tar -xf -
else
        [% c('remote_chroot/exec', { exec_cmd => 'cd ' _ src _ ' && tar -cf - .' }) %] | tar -xf -
fi
OPT_END
    remote_put => <<OPT_END,
[%
    SET src = shell_quote(c('put_src', { error_if_undef => 1 }));
    SET dst = shell_quote(c('put_dst', { error_if_undef => 1 }));
-%]
#!/bin/sh
set -e
if [ -f [% src %] ]
then
        cd \$(dirname [% src %])
        tar -cf - \$(basename [% src %]) | [% c('remote_chroot/exec', { exec_cmd => 'mkdir -p ' _ dst _ '&& cd ' _ dst _ '&& tar -xf -' }) %]
else
        cd [% src %]
        tar -cf . | [% c('remote_chroot/exec', { exec_cmd => 'mkdir -p' _ dst _ '&& cd ' _ dst _ '&& tar -xf -' }) %]
fi
OPT_END
    lsb_release => \&lsb_release_cache,
    distributions => [
        { lsb_release => { id => 'Mageia'}, pkg_type => 'rpm', },
        { lsb_release => { id => 'Fedora'}, pkg_type => 'rpm', },
        { lsb_release => { id => 'openSuSe'}, pkg_type => 'rpm', },
        { lsb_release => { id => 'MandrivaLinux'}, pkg_type => 'rpm', },
        { lsb_release => { id => 'Debian'}, pkg_type => 'deb', },
        { lsb_release => { id => 'Ubuntu'}, pkg_type => 'deb', },
    ],
    urlget => 'wget -O[% shell_quote(c("filename")) %] [% shell_quote(c("URL")) %]',
    sig_ext => [ qw(gpg asc sig) ],
    enable => 1,
    tar    => <<TAR_END,
[%- SET src = c('tar_src', { error_if_undef => 1 }) -%]
find [% src.join(' ') %] -executable -exec chmod 700 {} \\;
find [% src.join(' ') %] ! -executable -exec chmod 600 {} \\;
find [% src.join(' ') %] | sort | \
        tar --owner=root --group=root --mtime=@[% c('timestamp') %] [% c('tar_args', { error_if_undef => 1 }) %] -T -
TAR_END
    zip    => <<ZIP_END,
[%- SET src = c('zip_src', { error_if_undef => 1 }) -%]
find [% src.join(' ') %] -executable -exec chmod 700 {} \\;
find [% src.join(' ') %] ! -executable -exec chmod 600 {} \\;
find [% src.join(' ') %] | sort | \
        zip -@ -X [% c('zip_args', { error_if_undef => 1 }) %]
ZIP_END
    arch   => \&get_arch,
    input_files_by_name => \&input_files_by_name,
);

1;
# vim: expandtab sw=4
