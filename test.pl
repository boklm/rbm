#!/usr/bin/perl -w
use strict;
use File::Slurp;
use Test::More tests => 31;
use lib 'lib/';

sub set_target {
    $BURPS::config->{run}{target} = [@_];
}

sub set_distribution {
    $BURPS::config->{run}{distribution} = $_[0];
}

sub set_step {
    $BURPS::config->{step} = $_[0];
}

BEGIN { use_ok('BURPS') };
chdir 'test';
BURPS::load_config;
ok($BURPS::config, 'load config');

my @tests = (
    {
        name => 'simple',
        config => [ 'a', 'option_a' ],
        expected => 'a',
    },
    {
        name => 'project',
        config => [ 'a', 'project_a' ],
        expected => 'a',
    },
    {
        name => 'target',
        target => ['target_a'],
        config => [ 'a', 'option_a' ],
        expected => 'target a',
    },
    {
        name => 'target project',
        target => ['target_b'],
        config => [ 'a', 'option_a' ],
        expected => 'b',
    },
    {
        name => 'triple target - 1',
        target => [ 'target_a', 'target_b', 'target_c' ],
        config => [ 'a', 'option_a' ],
        expected => 'b',
    },
    {
        name => 'triple target - 2',
        target => [ 'target_c', 'target_a', 'target_b' ],
        config => [ 'a', 'option_a' ],
        expected => 'c',
    },
    {
        name => 'target redirect - 1',
        target => [ 'target_d' ],
        config => [ 'a', 'option_a' ],
        expected => 'target a',
    },
    {
        name => 'target redirect - 2',
        target => [ 'target_e' ],
        config => [ 'a', 'option_a' ],
        expected => 'b',
    },
    {
        name => 'target redirect - 3',
        target => [ 'target_f' ],
        config => [ 'a', 'option_a' ],
        expected => 'c',
    },
    {
        name => 'distro - 1',
        target => [ 'set_distro_a' ],
        config => [ 'a', 'option_b' ],
        expected => 'b_a',
    },
    {
        name => 'distro - 2',
        target => [ 'set_distro_b' ],
        config => [ 'a', 'option_b' ],
        expected => 'b_b',
    },
    {
        name => 'distro + target - 1',
        target => [ 'set_distro_a', 'target_g' ],
        config => [ 'a', 'option_c' ],
        expected => 'c_a',
    },
    {
        name => 'distro + target - 2',
        target => [ 'set_distro_b', 'target_g' ],
        config => [ 'a', 'option_c' ],
        expected => 'c_b',
    },
    {
        name => 'template func c',
        config => [ 'a', 'tmpl_c1' ],
        expected => 'a',
    },
    {
        name => 'template func pc',
        config => [ 'a', 'tmpl_pc1' ],
        expected => 'project b',
    },
    {
        name => 'template func pc + target',
        target => [ 'target_a' ],
        config => [ 'a', 'tmpl_pc1' ],
        expected => 't a',
    },
    {
        name => 'proj target - 1',
        target => [ 'b:target_a' ],
        config => [ 'a', 'option_a' ],
        expected => 'a',
    },
    {
        name => 'proj target - 2',
        target => [ 'b:target_a' ],
        config => [ 'a', 'tmpl_pc1' ],
        expected => 't a',
    },
    {
        name => 'perl sub',
        config => [ 'a', 'option_d/a' ],
        expected => 'A a',
    },
    {
        name => 'step config',
        step => 'build',
        config => [ 'c', 'option_e' ],
        expected => 'build e',
    },
    {
        name => 'redirect step config',
        step => 'redirect',
        config => [ 'c', 'option_e' ],
        expected => 'build e',
    },
    {
        name => 'step + target config',
        step => 'build',
        target => [ 'version_2' ],
        config => [ 'c', 'option_e' ],
        expected => 'build e - v2',
    },
    {
        name => 'distro config',
        target => [ 'set_distro_a' ],
        config => [ 'c', 'option_e' ],
        expected => 'distro_a - e',
    },
    {
        name => 'distro + step config',
        target => [ 'set_distro_a' ],
        step => 'build',
        config => [ 'c', 'option_e' ],
        expected => 'distro_a - build e',
    },
    {
        name => 'distro + step + target config',
        target => [ 'set_distro_a', 'version_2' ],
        step => 'build',
        config => [ 'c', 'option_e' ],
        expected => 'distro_a - build e - v2',
    },
    {
        name => 'srpm step',
        step => 'srpm',
        config => [ 'c', 'option_rpm' ],
        expected => '1',
    },
    {
        name => 'deb-src step',
        step => 'deb-src',
        config => [ 'c', 'option_deb' ],
        expected => '1',
    },
    {
        name => 'build + steps config - 1',
        target => [ 'version_1' ],
        build => [ 'c', 'build' ],
        files => { 'out/c-1' => "1-build e\n" },
    },
    {
        name => 'build + steps and targets config',
        target => [ 'version_2' ],
        build => [ 'c', 'build' ],
        files => { 'out/c-2' => "2-build e - v2\n" },
    },
);

foreach my $test (@tests) {
    set_target($test->{target} ? @{$test->{target}} : ());
    set_step($test->{step} ? $test->{step} : 'init');
    if ($test->{config}) {
        is(
            BURPS::project_config(@{$test->{config}}),
            $test->{expected},
            $test->{name}
        );
    }
    if ($test->{build}) {
        unlink keys %{$test->{files}};
        BURPS::build_run(@{$test->{build}});
        my $res = grep { read_file($_) ne $test->{files}{$_} } keys %{$test->{files}};
        ok(!$res, $test->{name});
    }
}
