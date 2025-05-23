#!/usr/bin/perl -w
use strict;
use Path::Tiny;
use Test::More tests => 45;
use lib 'lib/';

sub set_target {
    $RBM::config->{run}{target} = [@_];
}

sub set_distribution {
    $RBM::config->{run}{distribution} = $_[0];
}

sub set_step {
    $RBM::config->{step} = $_[0];
}

BEGIN { use_ok('RBM') };
chdir 'test';
RBM::load_config;
RBM::load_modules_config;
RBM::set_default_env;
ok($RBM::config, 'load config');

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
        name => 'option overriding',
        step => 'build',
        config => [ 'a', 'Z' ],
        expected => 'aZa AZa aZa',
    },
    {
        name => 'rpm step',
        step => 'rpm',
        config => [ 'c', 'option_rpm' ],
        expected => '1',
    },
    {
        name => 'deb step',
        step => 'deb',
        config => [ 'c', 'option_deb' ],
        expected => '1',
    },
    {
        name => 'Using option from rbm.module.conf',
        target => [],
        config => [ 'b', 'module_3'],
        expected => '3',
    },
    {
        name => 'Using option defined in multiple rbm.module.conf',
        target => [],
        config => [ 'b', 'module_m'],
        expected => '1',
    },
    {
        name => 'Using option defined in a module project',
        config => [ 'm1_a', 'm1_a' ],
        expected => 'm1_a',
    },
    {
        name => 'Using option defined in a module project and rbm.module.conf',
        config => [ 'm1_a', 'project_m' ],
        expected => 'm1_a',
    },
    {
        name => 'Using option defined in main projects and a module project',
        config => [ 'a', 'project_a' ],
        expected => 'a',
    },
    {
        name => 'Using template file from common project',
        config => [ 'a', 'c_1' ],
        expected => "c1\n",
    },
    {
        name => 'Using template file from common project in a module',
        config => [ 'a', 'c_2' ],
        expected => "c2\n",
    },
    {
        name => 'Using template file in multiple common directories',
        config => [ 'a', 'c_3' ],
        expected => "c3_main\n",
    },
    {
        name => 'Using template file in multiple modules common directories',
        config => [ 'a', 'c_4' ],
        expected => "c4_module1\n",
    },
    {
        name => 'Using template file in project directories in a module',
        config => [ 'm1_a', 'i' ],
        expected => "i1\n",
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
    {
        name => 'multi-projects build',
        target => [],
        build => [ 'r3', 'build', { pkg_type => 'build' } ],
        files => {
            'out/r1' => "1 - build\n",
            'out/r2' => "1 - build\n2 - build\n",
            'out/r3' => "1 - build\n2 - build\n3 - build\n",
        },
    },
    {
        name => 'multi-steps build with changing targets',
        target => [ 'target_a' ],
        build => [ 'change-targets', 'build', { pkg_type => 'build' } ],
        files => {
          'out/change-targets.txt' => "no\nz\ntta\n",
        },
    },
    {
        name => 'build project in a module',
        target => [],
        build => [ 'm3_a', 'build', { pkg_type => 'build' } ],
        files => {
          'out/m3-output' => "1 - build\n___m3\n"
        },
    },
    {
        name => 'mercurial repo',
        target => [],
        config => [ 'mozmill-automation', 't' ],
        expected => '432611daa42c7608d32b04c89ac26fbcea6a61663419aa88ead87116e212a004',
    },
    {
        name => 'mercurial repo build',
        target => [],
        build => [ 'mozmill-automation', 'build' ],
        files => {
            'out/mozmill-automation-bbad7215c713_sha256sum.txt' =>
            "ceeda3cd3285b6ed53233dc65e3beac82f2b284402a80ef6c1fcdf5b9861f068  s.txt\n",
        },
    },
    {
        name => 'build using files and directories as input',
        target => [],
        build => [ 'files_project', 'build', { pkg_type => 'build' } ],
        files => {
            'out/files_project-57a38d32f55ac3bec035f8531bbf4574d81c6ffc41a47bfc959dc8113b86be14' =>
            "1\n2\n3\n4\n1\n2\n",
        },
    },
    {
        name => 'sha256sum input_files',
        target => [ 'sha256sum' ],
        build  => [ 'shasum', 'build' ],
        files  => {},
    },
    {
        name => 'sha512sum input_files',
        target => [ 'sha512sum' ],
        build  => [ 'shasum', 'build' ],
        files  => {},
    },
    {
        name => 'wrong sha256sum input_files',
        target => [ 'wrong_sha256sum' ],
        fail_build  => [ 'shasum', 'build' ],
    },
    {
        name => 'wrong sha512sum input_files',
        target => [ 'wrong_sha512sum' ],
        fail_build  => [ 'shasum', 'build' ],
    },
);

foreach my $test (@tests) {
    set_target($test->{target} ? @{$test->{target}} : ());
    set_step($test->{step} ? $test->{step} : 'rbm_init');
    if ($test->{config}) {
        is(
            RBM::project_config(@{$test->{config}}),
            $test->{expected},
            $test->{name}
        );
    }
    if ($test->{build}) {
        unlink keys %{$test->{files}};
        RBM::build_run(@{$test->{build}});
        my $res = grep { path($_)->slurp_utf8 ne $test->{files}{$_} } keys %{$test->{files}};
        ok(!$res, $test->{name});
    }
    if ($test->{fail_build}) {
        my $pid = fork;
        if (!$pid) {
            close STDOUT;
            close STDERR;
            RBM::build_run(@{$test->{fail_build}});
            exit 0;
        }
        wait;
        my $exit_code = $?;
        ok($exit_code, $test->{name});
    }
}
