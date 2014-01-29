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

# ---
is(BURPS::project_config('a', 'option_a'), 'a', 'simple');
# ---
is(BURPS::project_config('a', 'project_a'), 'a', 'project');
# ---
set_target('target_a');
is(BURPS::project_config('a', 'option_a'), 'target a', 'target');
# ---
set_target('target_b');
is(BURPS::project_config('a', 'option_a'), 'b', 'target project');
# ---
set_target('target_a', 'target_b', 'target_c');
is(BURPS::project_config('a', 'option_a'), 'b', 'triple target - 1');
# ---
set_target('target_c', 'target_a', 'target_b');
is(BURPS::project_config('a', 'option_a'), 'c', 'triple target - 2');
# ---
set_target('target_d');
is(BURPS::project_config('a', 'option_a'), 'target a', 'target redirect - 1');
# ---
set_target('target_e');
is(BURPS::project_config('a', 'option_a'), 'b', 'target redirect - 2');
# ---
set_target('target_f');
is(BURPS::project_config('a', 'option_a'), 'c', 'target redirect - 3');
# ---
set_target('set_distro_a');
is(BURPS::project_config('a', 'option_b'), 'b_a', 'distro - 1');
# ---
set_target('set_distro_b');
is(BURPS::project_config('a', 'option_b'), 'b_b', 'distro - 2');
# ---
set_target('set_distro_a', 'target_g');
is(BURPS::project_config('a', 'option_c'), 'c_a', 'distro + target - 1');
# ---
set_target('set_distro_b', 'target_g');
is(BURPS::project_config('a', 'option_c'), 'c_b', 'distro + target - 2');
# ---
set_target();
is(BURPS::project_config('a', 'tmpl_c1'), 'a', 'template func c');
# ---
is(BURPS::project_config('a', 'tmpl_pc1'), 'project b', 'template func pc');
# ---
set_target('target_a');
is(BURPS::project_config('a', 'tmpl_pc1'), 't a', 'template func pc + target');
# ---
set_target('b:target_a');
is(BURPS::project_config('a', 'option_a'), 'a', 'proj target - 1');
# ---
is(BURPS::project_config('a', 'tmpl_pc1'), 't a', 'proj target - 2');
# ---
set_target();
is(BURPS::project_config('a', 'option_d/a'), 'A a', 'perl sub');
# ---
set_step('build');
is(BURPS::project_config('c', 'option_e'), 'build e', 'step config');
# ---
set_step('redirect');
is(BURPS::project_config('c', 'option_e'), 'build e', 'redirect step config');
# ---
set_target('version_2');
set_step('build');
is(BURPS::project_config('c', 'option_e'), 'build e - v2', 'step + target config');
# ---
set_target('set_distro_a');
set_step('init');
is(BURPS::project_config('c', 'option_e'), 'distro_a - e', 'distro config');
# ---
set_target('set_distro_a');
set_step('build');
is(BURPS::project_config('c', 'option_e'), 'distro_a - build e', 'distro + step config');
# ---
set_target('set_distro_a', 'version_2');
set_step('build');
is(BURPS::project_config('c', 'option_e'), 'distro_a - build e - v2', 'distro + step + target config');
# ---
set_step('srpm');
set_target();
is(BURPS::project_config('c', 'option_rpm'), '1', 'srpm step');
# ---
set_step('deb-src');
set_target();
is(BURPS::project_config('c', 'option_deb'), '1', 'deb-src step');
# ---
set_step('init');
set_target('version_1');
unlink 'out/c-1';
BURPS::build_run('c', 'build');
is(read_file('out/c-1'), "1-build e\n", 'build + steps config - 1');
# ---
set_target('version_2');
unlink 'out/c-2';
BURPS::build_run('c', 'build');
is(read_file('out/c-2'), "2-build e - v2\n", 'build + steps and targets config');
