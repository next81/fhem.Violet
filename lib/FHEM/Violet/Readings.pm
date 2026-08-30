# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;
use vars qw($unicodeEncoding %VIOLET_TARGET);

# Filterung, Normalisierung und Aktualisierung der FHEM-Readings.
# Die Implementierung bleibt im Paket main, damit FHEM-Callbacks und Kernhelfer
# ohne Adapter- oder Namensänderungen verwendet werden können.

# Entscheidet zentral über Änderungs-, Heartbeat- und Anfangsnull-Unterdrückung.
sub VIOLET_ShouldUpdateReading {
	my ($hash, $reading, $value, $always, $suppressInitialEmptyZero) = @_;
	return 1 if $always;

	my $exists = exists($hash->{READINGS}) && exists($hash->{READINGS}{$reading});

	# Neue Steuerungs-Readings nicht für leere/null Werte anlegen. Sobald ein Reading
	# existiert, sind null und leer gültige Übergänge und bei Änderung zu speichern.
	if (!$exists && $suppressInitialEmptyZero && VIOLET_IsInitialEmptyOrZero($value)) {
		return 0;
	}

	my $new = defined($value) ? "$value" : '';

	# Bestehende Readings behalten bei gleichem Wert Zeitstempel und Event.
	if ($exists) {
		my $old = defined($hash->{READINGS}{$reading}{VAL}) ? "$hash->{READINGS}{$reading}{VAL}" : '';
		return 0 if $old eq $new;
	}
	return 1;
}

# Text in die vom konfigurierten FHEM-Kern erwartete Darstellung umwandeln. Mit
# attr global encoding=unicode speichert FHEM Perl-Unicode. Im alten Bytestream-
# Modus erwartet FHEM/FHEMWEB dagegen UTF-8-Bytes; U+00FC würde sonst als 0xFC
# ausgegeben, obwohl die HTTP-Seite UTF-8 deklariert, und als U+FFFD erscheinen.
sub VIOLET_FhemValue {
	my ($value) = @_;
	return '' if !defined($value);
	return $value if ref($value);

	# Unicode-Modus behält echte Perl-Zeichenfolgen. Bytefolgen aus Push oder anderen
	# Nicht-JSON-Pfaden zuerst streng als UTF-8 dekodieren, sonst als Windows-1252.
	if ($unicodeEncoding) {
		return $value if utf8::is_utf8($value);

		my $decoded = eval { decode('UTF-8', $value, FB_CROAK) };
		return $decoded if !$@;
		return decode('Windows-1252', $value);
	}

	# Bytestream-Modus muss UTF-8-Bytes speichern. JSON liefert Perl-Unicode, daher
	# vor Vergleich und Speicherung genau einmal kodieren.
	return encode('UTF-8', $value) if utf8::is_utf8($value);
	return $value;
}

# Ein Reading innerhalb eines aktiven readingsBeginUpdate/readingsEndUpdate-
# Blocks unter Anwendung der gemeinsamen Änderungs-/Anfangsnullregeln aktualisieren.
sub VIOLET_BulkUpdateReading {
	my ($hash, $reading, $value, $always, $suppressInitialEmptyZero) = @_;

	# Vor dem Vergleich normalisieren, damit ein gleicher Umlautwert bei
	# Konfigurationsabrufen nicht zwischen Perl-Unicode und UTF-8-Bytes wechselt.
	$value = VIOLET_FhemValue($value);
	return 0 if !VIOLET_ShouldUpdateReading($hash, $reading, $value, $always, $suppressInitialEmptyZero);

	readingsBulkUpdate($hash, $reading, $value);
	return 1;
}

# Einzelnes Reading mit derselben Regel wie Sammelaktualisierungen schreiben. So
# bleiben unveränderte Fehler-/Anmeldedaten ruhig, während state bei Bedarf als
# Herzschlag erzwungen werden kann.
sub VIOLET_SingleUpdateReading {
	my ($hash, $reading, $value, $always, $suppressInitialEmptyZero) = @_;

	# Dieselbe Kernkodierungs-Normalisierung wie bei Sammelaktualisierungen anwenden.
	$value = VIOLET_FhemValue($value);
	return 0 if !VIOLET_ShouldUpdateReading($hash, $reading, $value, $always, $suppressInitialEmptyZero);

	readingsSingleUpdate($hash, $reading, $value, 1);
	return 1;
}

# Dekodiert eine API-Antwort, filtert aktive Schlüssel und aktualisiert ihre Readings.
sub VIOLET_ParseJsonToReadings {
	my ($hash, $body, $prefix, $activeFilter) = @_;
	VIOLET_LogCall($hash, 'VIOLET_ParseJsonToReadings', 'prefix='.($prefix // ''), 'activeFilter='.($activeFilter ? 1 : 0), 'bodyLength='.length($body // ''));
	my ($obj, $jsonErr) = VIOLET_DecodeJsonResponse($body);

	# Nur strukturierte JSON-Antworten akzeptieren. Fehlerhafte Klartextdaten als
	# Fehler erfassen, statt daraus beliebige Readings zu bilden.
	if (defined($jsonErr) || (!ref($obj))) {
		VIOLET_Log($hash, 1, 'critical JSON parse error: '.
			VIOLET_LogValue($jsonErr // 'response is not structured JSON'));
		VIOLET_SingleUpdateReading($hash, 'lastError', 'invalid JSON response', 0, 0);
		return;
	}

	# Firmware-/API-Varianten können Werte unter getReadings einhüllen. Beide Formen
	# vor dem Abflachen normalisieren, damit Push-/Pull-Namen identisch bleiben.
	if ((!defined($prefix) || $prefix eq '') && ref($obj) eq 'HASH' && ref($obj->{getReadings})) {
		$obj = $obj->{getReadings};
	}

	my %flat;
	VIOLET_Flatten('', $obj, \%flat);

	# Aktuelle Upstream-API nachbilden: EXT*-Schlüssel können ohne Erweiterung
	# erscheinen. Ohne passenden Lebenszähler entfernen.
	my ($ext1Alive, $ext2Alive) = (0, 0);

	# Zuerst ausschließlich die belastbaren Lebenszähler der Erweiterungen suchen.
	for my $key (keys %flat) {
		my $safe = uc(VIOLET_SanitizeReading($key));
		$ext1Alive = 1 if $safe eq 'SYSTEM_EXT1MODULE_ALIVE_COUNT';
		$ext2Alive = 1 if $safe eq 'SYSTEM_EXT2MODULE_ALIVE_COUNT';
	}

	# Danach Platzhalterwerte aller nicht nachgewiesenen Erweiterungsbanken entfernen.
	for my $key (keys %flat) {
		my $safe = uc(VIOLET_SanitizeReading($key));
		delete $flat{$key} if !$ext1Alive && $safe =~ /^EXT1_[1-8](?:_|$)/;
		delete $flat{$key} if !$ext2Alive && $safe =~ /^EXT2_[1-8](?:_|$)/;
	}

	# Hardwaremerkmale nur aus der ungepräfixten automatischen Polling-Antwort ableiten.
	if ((!defined($prefix) || $prefix eq '') && $activeFilter) {
		VIOLET_UpdateHardwareCapabilities($hash, \%flat);
	}

	readingsBeginUpdate($hash);

	# Alle verbleibenden API-Werte deterministisch auf kanonische Readings abbilden.
	for my $key (sort keys %flat) {
		my $safe = uc(VIOLET_SanitizeReading($key));

		# Eine geänderte Steuerungsmarkierung verwirft die Konfiguration im Cache. Die
		# Markierung dient nur intern und wird bewusst kein eigenes Reading.
		if ((!defined($prefix) || $prefix eq '') && $safe eq 'CONFIGCHANGEMARKER') {
			my $marker = defined($flat{$key}) ? "$flat{$key}" : '';

			# Nur ein tatsächlicher Markerwechsel macht die bisherige Discovery veraltet.
			if (defined($hash->{VIOLET_CONFIG_CHANGE_MARKER}) && $hash->{VIOLET_CONFIG_CHANGE_MARKER} ne $marker) {
				$hash->{VIOLET_CONFIG_DISCOVERED_AT} = 0;
			}
			$hash->{VIOLET_CONFIG_CHANGE_MARKER} = $marker;
			next;
		}

		# Automatisches Polling speichert nur Schlüssel konfigurierter Funktionen.
		# Ausdrückliche manuelle Gruppen umgehen den Filter zur Diagnose.
		next if $activeFilter && !VIOLET_IsActiveApiKey($hash, $key);

		my $reading = VIOLET_PrefixedReading($prefix, $key);
		VIOLET_BulkUpdateReading($hash, $reading, $flat{$key}, 0, 1);
	}

	readingsEndUpdate($hash, 1);
}

# VIOLET-interne API-Schlüssel vor der lowerCamelCase-Umwandlung normalisieren.
# Dieselbe Funktion für Polling, Get und HTTP-Push sorgt dafür, dass ein Wert
# stets dasselbe FHEM-Reading aktualisiert.
sub VIOLET_CanonicalApiKey {
	my ($key) = @_;
	my $safe = VIOLET_SanitizeReading($key);

	# VIOLETs gemischtes pH-Präfix, etwa pH_value, großschreiben, damit die
	# lowerCamelCase-Umwandlung ph statt pH erzeugt.
	$safe =~ s/^PH(?=_|$)/PH/i;

	# Potentiometrischen Chlorsensornamen in den öffentlichen FHEM-Begriff übersetzen.
	# ORP braucht keine eigene fachliche Zuordnung, weil die allgemeine Regel
	# fooValue -> foo später bereits orp erzeugt.
	if ($safe =~ /^POT_VALUE(?=_|$)/i) {
		$safe =~ s/^POT_VALUE/CHLOR_VALUE/i;
		return $safe;
	}

	# VIOLETs Polaritätsfelder der Elektrolyse normalisieren. Der normale Kanal ist
	# DOS_2_ELO, die Polarität kommt als DOS_2_CURRENT_POLARITY und der Umkehrkanal
	# als DOS_3_ELO_REV*. Beide dem öffentlichen Namensraum dosageElectrolysis*
	# zuordnen, damit interne Kanalnummern nicht in Reading-Namen gelangen.
	if ($safe =~ /^DOS_2_CURRENT_POLARITY(?=_|$)/i) {
		$safe =~ s/^DOS_2_CURRENT_POLARITY/DOSAGE_ELECTROLYSIS_POLARITY/i;
		return $safe;
	}

	# Vollständiges Umkehrkanalpräfix zuordnen, damit optionale Endungen wie LAST_ON,
	# LAST_OFF, RUNTIME oder firmwarespezifische Felder konsistent bleiben.
	if ($safe =~ /^DOS_3_ELO_REV(?=_|$)/i) {
		$safe =~ s/^DOS_3_ELO_REV/DOSAGE_ELECTROLYSIS_REVERSE/i;
		return $safe;
	}

	# Durch verschachteltes JSON duplizierte Hülle der Digitaleingangsregel kürzen.
	# Manche Firmwarevarianten liefern zusätzlich ein äußeres Zustandssegment. Die
	# Eingangsnummer vom inneren Feldende für beide Formen nach vorn verschieben.
	if ($safe =~ /^DIGITALINPUTRULE_(?:([A-Z0-9]+)_)?DIGITALINPUT_RULE_(.+)$/i) {
		my ($outer, $inner) = (defined($1) ? uc($1) : '', uc($2));

		# STOPWATCH1 + STATE wird DI1_RULE_STOPWATCH_STATE; ohne äußeres Segment wird
		# STOPWATCH1 entsprechend zu DI1_RULE_STOPWATCH.
		if ($inner =~ /^(.*?)(\d+)$/) {
			my ($field, $number) = ($1, $2);
			my @parts = ('DI'.$number, 'RULE');
			push @parts, $field if length $field;
			push @parts, $outer if length $outer;
			return join('_', @parts);
		}

		# Unbekannte nicht nummerierte Felder deterministisch erhalten.
		return join('_', grep { length($_) } ('DI', 'RULE', $inner, $outer));
	}

	# Mit den genauen VIOLET-Schlüsseln der Sollwerttabelle vergleichen. Das entfernt
	# doppelte Zuordnungen und hält Set-/Get-Namen bei zentralen Änderungen synchron.
	for my $target (keys %VIOLET_TARGET) {
		my $meta = $VIOLET_TARGET{$target};

		# Nach Bereinigung ohne Beachtung der Groß-/Kleinschreibung vergleichen, da
		# VIOLETs Schreibweise nicht Teil des öffentlichen Reading-Namens ist.
		if (uc($safe) eq uc(VIOLET_SanitizeReading($meta->{configKey}))) {
			return $meta->{canonical};
		}
	}

	# Beide VIOLET-Chemieschemata, DOS_x_*-Laufzeit/Ausgang und DOSAGE_*-Konfiguration,
	# auf dasselbe öffentliche Reading-Präfix dosage<Type> normalisieren. Nur die
	# kanonischen FHEM-Chemienamen aus %VIOLET_CHEM berücksichtigen.
	for my $type (qw(chlor electrolysis phminus phplus floc h2o2)) {
		my $chem = $VIOLET_CHEM{$type};
		my $canonical = 'DOSAGE_'.uc($type);

		# Laufzeit-/Ausgangsschlüssel wie DOS_1_CL_* mit dem Kanalausgang abgleichen.
		if (defined($chem->{output})) {
			my $output = VIOLET_SanitizeReading($chem->{output});

			# Ausgangstoken nur am Anfang und an Schlüsselgrenze vergleichen, damit ähnlich
			# benannte fremde Schlüssel nicht versehentlich umgeschrieben werden.
			if ($safe =~ /^\Q$output\E(?=_|$)/i) {
				$safe =~ s/^\Q$output\E/$canonical/i;
				return $safe;
			}
		}

		# Konfigurationsschlüssel wie DOSAGE_chlorine_* mit dem Präfix abgleichen.
		if (defined($chem->{configPrefix})) {
			my $configPrefix = VIOLET_SanitizeReading($chem->{configPrefix});

			# Denselben grenzsicheren Vergleich auf DOSAGE_*-Präfixe anwenden.
			if ($safe =~ /^\Q$configPrefix\E(?=_|$)/i) {
				$safe =~ s/^\Q$configPrefix\E/$canonical/i;
				return $safe;
			}
		}
	}

	# Unbekannte/nicht besondere API-Schlüssel unverändert durchreichen und durch
	# VIOLET_CamelCaseReading in lowerCamelCase umwandeln.
	return $safe;
}

# Wandelt einen kanonischen API-Schlüssel in einen stabilen lowerCamelCase-Readingnamen um.
sub VIOLET_CamelCaseReading {
	my ($key) = @_;
	my $safe = VIOLET_CanonicalApiKey($key);
	my @parts = grep { $_ ne '' } split(/_+/, $safe);
	@parts = ('value') if !@parts;

	my @out;

	# Durch Unterstriche getrennte API-Segmente in lowerCamelCase umwandeln und von
	# VIOLET gelieferte Segmente mit gemischter Schreibweise erhalten.
	for my $i (0 .. $#parts) {
		my $part = $parts[$i];
		$part = lc($part) if $part =~ /^[A-Z0-9]+$/;

		# Erstes Segment klein lassen und nur folgende groß beginnen, um einen üblichen
		# lowerCamelCase-Namen für FHEM-Readings zu bilden.
		if ($i == 0) {
			substr($part, 0, 1, lc(substr($part, 0, 1))) if length($part);
		} else {
			substr($part, 0, 1, uc(substr($part, 0, 1))) if length($part);
		}
		push @out, $part;
	}

	my $reading = join('', @out);

	# Messwertnamen: fooValue -> foo, fooValueMin/Max -> fooMin/Max.
	$reading =~ s/ValueMin$/Min/;
	$reading =~ s/ValueMax$/Max/;
	$reading =~ s/Value$//;

	$reading = 'value'.$reading if $reading =~ /^\d/;
	return $reading || 'value';
}

# Setzt ein optionales fachliches Präfix vor den kanonischen Readingnamen.
sub VIOLET_PrefixedReading {
	my ($prefix, $key) = @_;

	# OneWire-Anzeigenamen sind Metadaten derselben nummerierten Sensoren. Neben
	# onewireN/onewireNState anzeigen, statt unter configNamesOnewireN zu verstecken.
	if (defined($prefix) && lc($prefix) eq 'config' && $key =~ /(?:^|_)NAMES_onewire(\d+)$/i) {
		return 'onewire'.$1.'Name';
	}

	my $reading = VIOLET_CamelCaseReading($key);
	return $reading if !defined($prefix) || $prefix eq '';
	my $p = VIOLET_CamelCaseReading($prefix);
	substr($reading, 0, 1, uc(substr($reading, 0, 1))) if length($reading);
	return $p.$reading;
}


1;
