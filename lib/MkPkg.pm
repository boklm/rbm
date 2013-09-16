package MkPkg;

use warnings;
use strict;
use Cwd qw(abs_path getcwd);
use YAML qw(LoadFile);
use Template;
use File::Basename;
use IO::Handle;
use IO::CaptureOutput qw(capture_exec);
#use Data::Dump qw/dd/;

our $config;
sub load_config {
    my $config_file = shift // find_config_file();
    $config = LoadFile($config_file);
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
    foreach my $path (@_) {
        if (my $r = config_p(@$path, $name)) {
            return $r;
        }
    }
    return $config->{$name};
}

sub project_config {
    config($_[0], ['run'], ['projects', $_[1]]);
}

sub exit_error {
    print STDERR $_[0], "\n";
    exit defined $_[1] ? $_[1] : 1;
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

sub maketar {
    my ($project, $dest_dir) = @_;
    $dest_dir //= abs_path(path(project_config('output_dir', $project)));
    my $clonedir = path(config('git_clone_dir', [ 'projects', $project ]));
    my $old_cwd = getcwd;
    if (!chdir path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        if (system('git', 'clone',
                $config->{projects}{$project}{git_url}, $project) != 0) {
            exit_error "Error cloning $config->{projects}{$project}{git_url}";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    system('git', 'pull') == 0 || exit_error "Error running git pull on $project";
    my $git_hash = project_config('git_hash', $project)
        || exit_error 'No git_hash specified';
    my $version = project_config('version', $project)
        || exit_error 'No version specified';
    system('git', 'archive', "--prefix=$project-$version/",
        "--output=$dest_dir/$project-$version.tar.gz", $git_hash) == 0
        || exit_error 'Error running git archive.';
    print "Created $dest_dir/$project-$version.tar.gz\n";
}

1;
