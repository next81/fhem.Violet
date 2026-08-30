# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

use strict;
use warnings;

use Test2::V0;

my @productionFiles = (
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
my @testFiles = grep {
	$_ ne 'tests/function_inventory.t'
} glob('tests/*.t');

sub readFile {
	my ($file) = @_;
	open my $handle, '<', $file
		or die "cannot read $file: $!";
	local $/;
	my $content = <$handle>;
	close $handle;
	return $content;
}

ok(-d 'tests', 'unit-test directory is named tests');
ok(!-d 't', 'legacy t directory does not exist');

my $productionSource = join("\n", map { readFile($_) } @productionFiles);
my $testSource = join("\n", map { readFile($_) } @testFiles);
my @functions = $productionSource =~ /^sub\s+(VIOLET_[A-Za-z0-9_]+)/gm;

is(scalar(@functions), 78, 'all current production functions are inventoried');

for my $function (sort @functions) {
	ok(
		$testSource =~ /\b\Q$function\E\s*\(/,
		"$function has a direct unit-test invocation"
	);
}

my $runtimeSource = $productionSource;
$runtimeSource =~ s/^=pod\b.*?^=cut\b//gms;
$runtimeSource =~ s/^\s*#.*$//gm;

for my $function (sort @functions) {
	my $withoutDefinition = $runtimeSource;
	$withoutDefinition =~ s/^sub\s+\Q$function\E\b[^\n]*//m;
	my $referenced = $function eq 'VIOLET_Initialize'
		|| $withoutDefinition =~ /\b\Q$function\E\s*\(/
		|| $withoutDefinition =~ /['"]\Q$function\E['"]/;
	ok($referenced, "$function is referenced by production code or FHEM");
}

done_testing();
