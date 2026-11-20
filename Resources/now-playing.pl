#!/usr/bin/perl
# Loads StableBar's now-playing library into perl and runs one of its entry points: `watch` prints StableBar's output
# for what plays now and for each change, and `send COMMAND` sends a command to the playing app. MediaRemote answers
# perl, one of Apple's binaries, where it no longer answers other apps (macOS 15.4 and later).
use strict;
use warnings;
use DynaLoader;

$| = 1;
my ($library, $mode) = @ARGV;
die "usage: now-playing.pl LIBRARY watch | send COMMAND\n" unless defined $library && defined $mode;
my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error() . "\n";
my $entry = DynaLoader::dl_find_symbol($handle, "stablebar_now_playing_$mode") or die DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::run", $entry);
run();
