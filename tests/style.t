# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

use strict;
use warnings;

use File::Find qw(find);
use Test2::V0;

my @files = ('FHEM/50_Violet.pm');
my @productionFiles = (
	'FHEM/50_Violet.pm',
	glob('lib/FHEM/Violet/*.pm'),
);
my $legacyFramework = join('::', 'Test', 'More');
find(
	sub {
		return if !-f $_ || $_ !~ /\.(?:pm|pl|t)$/;
		push @files, $File::Find::name;
	},
	'lib',
	'tests'
);

for my $file (sort @files) {
	open my $handle, '<', $file
		or die "cannot read $file: $!";

	my @invalidIndentation;
	my @legacyTestFramework;
	my @trailingWhitespace;
	my $lineNumber = 0;
	while (my $line = <$handle>) {
		$lineNumber++;
		push @invalidIndentation, $lineNumber
			if $line =~ /^ +\S/ || $line =~ /^\t+ +\S/;
		push @legacyTestFramework, $lineNumber
			if index($line, $legacyFramework) >= 0;
		push @trailingWhitespace, $lineNumber
			if $line =~ /[ \t]+(?:\r?\n)?$/;
	}
	close $handle;

	is(
		\@invalidIndentation,
		[],
		"$file uses tabs only for indentation"
	);
	is(
		\@legacyTestFramework,
		[],
		"$file does not use the legacy test framework"
	);
	is(
		\@trailingWhitespace,
		[],
		"$file has no trailing whitespace"
	);
}

for my $file (sort @productionFiles) {
	open my $handle, '<', $file
		or die "cannot read $file: $!";
	my @lines = <$handle>;
	close $handle;

	my @undocumentedConditions;
	my @undocumentedFunctions;
	my @undocumentedLoops;
	my @unseparatedLoops;

	# Produktionscode zeilenweise auf die vereinbarten Kommentargrenzen prüfen.
	for my $index (0 .. $#lines) {
		my $line = $lines[$index];
		my $previous = $index - 1;
		$previous-- while $previous >= 0 && $lines[$previous] =~ /^\s*$/;

		# Jede Funktion benötigt unmittelbar oberhalb eine fachliche Zweckbeschreibung.
		if ($line =~ /^sub\s+/) {
			push @undocumentedFunctions, $index + 1
				if $previous < 0 || $lines[$previous] !~ /^\s*#/;
		}

		# Blockbedingungen benötigen eine Beschreibung der geprüften fachlichen Aussage.
		if ($line =~ /^\s*if\s*\(/) {
			push @undocumentedConditions, $index + 1
				if $previous < 0 || $lines[$previous] !~ /^\s*#/;
		}

		next if $line !~ /^(\t*)(?:for|while|until)\s+/;
		my $indentation = $1;

		# Schleifen werden inhaltlich erklärt und als eigener Absatz begonnen.
		if ($previous < 0 || $lines[$previous] !~ /^\s*#/) {
			push @undocumentedLoops, $index + 1;
		} else {
			my $beforeComment = $previous;
			$beforeComment-- while $beforeComment >= 0 && $lines[$beforeComment] =~ /^\s*#/;
			push @unseparatedLoops, $index + 1
				if $beforeComment >= 0 && $lines[$beforeComment] !~ /^\s*$/;
		}

		# Das Ende der Schleife muss ebenfalls durch eine Leerzeile hervorgehoben sein.
		my $closingLine;

		for my $scan ($index + 1 .. $#lines) {
			if ($lines[$scan] =~ /^\Q$indentation\E\}\s*$/) {
				$closingLine = $scan;
				last;
			}
		}

		push @unseparatedLoops, $index + 1
			if defined($closingLine)
			&& $closingLine < $#lines
			&& $lines[$closingLine + 1] !~ /^\s*$/;
	}

	is(\@undocumentedFunctions, [], "$file documents every function");
	is(\@undocumentedConditions, [], "$file documents every block condition");
	is(\@undocumentedLoops, [], "$file documents every loop");
	is(\@unseparatedLoops, [], "$file separates every loop with blank lines");
}

done_testing();
