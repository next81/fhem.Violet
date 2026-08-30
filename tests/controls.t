# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

use strict;
use warnings;

use Test2::V0;

my $controlsFile = 'controls_violet.txt';
my @runtimeFiles = (
	'FHEM/50_Violet.pm',
	'lib/FHEM/Violet/Commands.pm',
	'lib/FHEM/Violet/Discovery.pm',
	'lib/FHEM/Violet/ErrorCodes.pm',
	'lib/FHEM/Violet/Helpers.pm',
	'lib/FHEM/Violet/Logging.pm',
	'lib/FHEM/Violet/Module.pm',
	'lib/FHEM/Violet/Readings.pm',
	'lib/FHEM/Violet/Transport.pm',
);

open my $handle, '<', $controlsFile
	or die "cannot read $controlsFile: $!";
my @lines = <$handle>;
close $handle;

my %entries;
for my $line (@lines) {
	chomp $line;
	like(
		$line,
		qr/^UPD \d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2} \d+ \S+$/,
		'controls entry has valid FHEM update format'
	);
	my (undef, $timestamp, $size, $file) = split / /, $line, 4;
	$entries{$file} = {
		size      => $size,
		timestamp => $timestamp,
	};
}

is(
	[sort keys %entries],
	[sort @runtimeFiles],
	'controls file contains exactly all runtime files'
);

for my $file (@runtimeFiles) {
	ok(-f $file, "$file exists");
	is($entries{$file}{size}, -s $file, "$file size is current");
}

done_testing();
