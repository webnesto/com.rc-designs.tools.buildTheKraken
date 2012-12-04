#!/usr/bin/perl

use 5.000;

use FindBin qw($Bin);
use lib "${FindBin::Bin}/lib";

use BuildTheKraken;

BuildTheKraken::run( @ARGV );
