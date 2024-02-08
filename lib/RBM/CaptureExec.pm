package RBM::CaptureExec;

use Capture::Tiny qw(capture);

BEGIN {
    require Exporter;
    our @ISA = qw(Exporter);
    our @EXPORT = qw(capture_exec);
    our @EXPORT_OK = qw(capture_exec);
}

sub capture_exec {
    my @cmd = @_;
    my ($stdout, $stderr, $exit) = capture {
        system(@cmd);
    };
    return ($stdout, $stderr, $exit == 0, $exit) if wantarray();
    return $stdout;
}

1;
