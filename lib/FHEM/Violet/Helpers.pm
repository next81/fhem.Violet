# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package FHEM::Violet::Helpers;

use strict;
use warnings;

use Encode qw(decode FB_CROAK);
use Exporter qw(import);
use JSON::PP qw(encode_json);
use URI::Escape qw(uri_escape_utf8);
use utf8 ();

our @EXPORT_OK = qw(
	VIOLET_BroadReadingsQuery
	VIOLET_ConfigFlatValue
	VIOLET_ConfigValueEnabled
	VIOLET_DecodeJsonResponse
	VIOLET_Flatten
	VIOLET_FormEncode
	VIOLET_IsInitialEmptyOrZero
	VIOLET_IsNumber
	VIOLET_IsUInt
	VIOLET_LogValue
	VIOLET_ParseQuery
	VIOLET_SanitizeReading
	VIOLET_ServiceApiSuffix
	VIOLET_ServiceCommandSuffix
	VIOLET_ServiceExists
	VIOLET_ServiceFromSetCommand
	VIOLET_ServiceNames
	VIOLET_ServicePath
	VIOLET_UrlDecode
	VIOLET_ValidateValueGroups
);

my @VIOLET_SERVICES = qw(
	ftp samba ssh shairport homebridge alexa tunnel support_tunnel
);

# Formatiert einen beliebigen Skalar sicher und einzeilig fuer Diagnosemeldungen.
sub VIOLET_LogValue {
	my ($value) = @_;

	# Nichtskalare Werte werden nur ueber ihren Typ sichtbar, nie ueber ihren Inhalt.
	return '<undef>' if !defined($value);
	return '<'.ref($value).'>' if ref($value);

	my $text = "$value";
	$text =~ s/\\/\\\\/g;
	$text =~ s/\r/\\r/g;
	$text =~ s/\n/\\n/g;
	$text =~ s/\t/\\t/g;
	return $text;
}

# Liefert die vollstaendige, zentral gepflegte Liste schaltbarer VIOLET-Dienste.
sub VIOLET_ServiceNames {
	return @VIOLET_SERVICES;
}

# Prueft, ob ein Dienstname von der dokumentierten VIOLET-API unterstuetzt wird.
sub VIOLET_ServiceExists {
	my ($service) = @_;
	return scalar grep { $_ eq $service } @VIOLET_SERVICES;
}

# Wandelt einen internen Dienstnamen in das Suffix der VIOLET-API um.
sub VIOLET_ServiceApiSuffix {
	my ($service) = @_;
	my $suffix = uc($service // '');
	$suffix =~ s/_//g;
	return $suffix;
}

# Baut fuer einen bekannten Dienst den passenden enable- oder disable-Endpunkt.
sub VIOLET_ServicePath {
	my ($service, $state) = @_;

	# Unbekannte Dienste duerfen keinen frei konstruierten API-Pfad erzeugen.
	return undef if !VIOLET_ServiceExists($service);

	my $verb = $state eq 'on' ? 'enable' : 'disable';
	return '/'.$verb.VIOLET_ServiceApiSuffix($service);
}

# Wandelt einen Dienstnamen in das CamelCase-Suffix seines Set-Befehls um.
sub VIOLET_ServiceCommandSuffix {
	my ($service) = @_;
	return join('', map { ucfirst(lc($_)) } split /_/, $service);
}

# Loest einen Set-Befehl wie serviceSupportTunnel auf den internen Dienstnamen auf.
sub VIOLET_ServiceFromSetCommand {
	my ($cmd) = @_;

	# Alle freigegebenen Dienste gegen ihre kanonische Set-Schreibweise vergleichen.
	for my $service (@VIOLET_SERVICES) {
		return $service
			if lc($cmd // '') eq lc('service'.VIOLET_ServiceCommandSuffix($service));
	}

	return undef;
}

# Bewertet heterogene Konfigurationswerte als aktiv oder explizit deaktiviert.
sub VIOLET_ConfigValueEnabled {
	my ($value) = @_;

	# Fehlende, leere und uebliche negative Darstellungen gelten als deaktiviert.
	return 0 if !defined($value);

	my $normalized = "$value";
	$normalized =~ s/^\s+|\s+$//g;
	return 0 if $normalized eq '';
	return 0
		if $normalized =~ /^(?:0+(?:\.0+)?|false|off|no|none|disabled|n\/a)$/i;
	return 1;
}

# Findet einen Konfigurationswert trotz abweichender Trennzeichen oder Schreibweise.
sub VIOLET_ConfigFlatValue {
	my ($flat, $wanted) = @_;

	# Nur bereits abgeflachte Hashstrukturen koennen durchsucht werden.
	return undef if ref($flat) ne 'HASH';

	my $needle = uc(VIOLET_SanitizeReading($wanted));

	# Normalisierte Schluessel statt firmwareabhaengiger Rohschreibweisen vergleichen.
	for my $key (keys %$flat) {
		return $flat->{$key}
			if uc(VIOLET_SanitizeReading($key)) eq $needle;
	}

	return undef;
}

# Dekodiert eine HTTP-Antwort robust als Unicode-JSON und liefert Fehler separat.
sub VIOLET_DecodeJsonResponse {
	my ($body) = @_;

	# Eine fehlende Antwort ist von syntaktisch ungueltigem JSON unterscheidbar.
	return (undef, 'empty response') if !defined($body);

	my $text;

	# Bereits dekodierte Perl-Zeichen unveraendert lassen, Bytefolgen zuerst als UTF-8 lesen.
	if (utf8::is_utf8($body)) {
		$text = $body;
	} else {
		my $decodedUtf8 = eval { decode('UTF-8', $body, FB_CROAK) };
		$text = !$@ ? $decodedUtf8 : decode('Windows-1252', $body);
	}

	my $object = eval { JSON::PP->new->utf8(0)->decode($text) };
	return (undef, $@ || 'invalid JSON response') if $@ || !defined($object);
	return ($object, undef);
}

# Liefert die breite Startabfrage, bevor eine optimierte Discovery-Liste vorliegt.
sub VIOLET_BroadReadingsQuery {
	return 'ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM';
}

# Validiert eine oder mehrere kommaseparierte getReadings-Gruppen gegen die API.
sub VIOLET_ValidateValueGroups {
	my @groups = @_;
	my %valid = map { $_ => 1 }
		qw(ALL DOSAGE RUNTIMES PUMPPRIOSTATE BACKWASH SYSTEM);

	# Jede uebergebene Gruppe kann selbst mehrere kommaseparierte Werte enthalten.
	for my $group (@groups) {

		# Jeden Einzelwert normalisieren und gegen die feste Positivliste pruefen.
		for my $part (split(/,/, $group // '')) {
			my $normalized = uc($part);
			return 'invalid values group: '.$part if !$valid{$normalized};
		}

	}

	return undef;
}

# Erkennt leere oder semantische Nullwerte, die bei einem neuen Reading entfallen sollen.
sub VIOLET_IsInitialEmptyOrZero {
	my ($value) = @_;

	# Fehlende, leere und ausdruecklich nicht konfigurierte Sensorwerte unterdruecken.
	return 1 if !defined($value);

	my $text = "$value";
	return 1 if $text =~ /^\s*$/;
	return 1 if uc($text) eq 'NO_SENSOR_CONFIGURED';
	return 1
		if $text =~ /^\s*[+-]?(?:0+(?:\.0*)?|\.0+)(?:[eE][+-]?\d+)?\s*$/;

	my $duration = lc($text);
	$duration =~ s/\s+//g;

	# Auch strukturierte Null-Laufzeiten und leere Container gelten als Anfangsnull.
	return 1
		if $duration =~ /^(?:(?:0+d)?(?:0+h)?(?:0+m)?(?:0+s)?)$/
		&& $duration =~ /[dhms]/;
	return 1 if $duration =~ /^(?:0{1,2}:){1,2}0{1,2}$/;
	return 1 if $duration eq '[]' || $duration eq '{}';
	return 0;
}

# Reduziert verschachtelte JSON-Strukturen rekursiv auf flache API-Schluessel.
sub VIOLET_Flatten {
	my ($prefix, $value, $output) = @_;

	# Hashes werden rekursiv mit einem aus dem bisherigen Pfad gebildeten Praefix entfaltet.
	if (ref($value) eq 'HASH') {

		# Jeder Kindschluessel erhaelt einen stabilen, durch Unterstrich getrennten Pfad.
		for my $key (keys %$value) {
			my $path = $prefix eq '' ? $key : $prefix.'_'.$key;
			VIOLET_Flatten($path, $value->{$key}, $output);
		}

	# Arrays bleiben als kanonischer JSON-Wert erhalten, weil sie kein Reading-Unterobjekt sind.
	} elsif (ref($value) eq 'ARRAY') {
		$output->{$prefix || 'value'} = encode_json($value);
	# Sonstige Objekte werden ohne Zugriff auf ihre Interna als String uebernommen.
	} elsif (ref($value)) {
		$output->{$prefix || 'value'} = "$value";
	# Skalare und undef bilden die eigentlichen flachen Reading-Werte.
	} else {
		$output->{$prefix || 'value'} = defined($value) ? $value : '';
	}
}

# Bereinigt einen beliebigen API-Schluessel zu einem stabilen Reading-Token.
sub VIOLET_SanitizeReading {
	my ($value) = @_;
	$value //= 'value';
	$value =~ s/[^A-Za-z0-9]+/_/g;
	$value =~ s/^_+|_+$//g;
	return $value eq '' ? 'value' : $value;
}

# Zerlegt eine URL-Query in dekodierte Schluessel/Wert-Paare fuer den Push-Empfang.
sub VIOLET_ParseQuery {
	my ($query) = @_;
	my %parameters;

	# Sowohl kaufmaennisches Und als auch Semikolon als Query-Trenner akzeptieren.
	for my $part (split(/[&;]/, $query // '')) {
		next if $part eq '';
		my ($key, $value) = split(/=/, $part, 2);
		$key = VIOLET_UrlDecode($key // '');
		$value = VIOLET_UrlDecode($value // '');

		# Leere Parameternamen werden verworfen, Werte duerfen dagegen leer bleiben.
		$parameters{$key} = $value if $key ne '';
	}

	return %parameters;
}

# Dekodiert Pluszeichen und Prozentsequenzen einer einzelnen URL-Komponente.
sub VIOLET_UrlDecode {
	my ($value) = @_;
	$value //= '';
	$value =~ tr/+/ /;
	$value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
	return $value;
}

# Kodiert ein Hash deterministisch als application/x-www-form-urlencoded-Body.
sub VIOLET_FormEncode {
	my ($object) = @_;
	return join(
		'&',
		map {
			uri_escape_utf8($_).'='.
				uri_escape_utf8(defined($object->{$_}) ? $object->{$_} : '')
		} sort keys %$object
	);
}

# Prueft einen Wert auf die dezimale Schreibweise einer vorzeichenlosen Ganzzahl.
sub VIOLET_IsUInt {
	my ($value) = @_;
	return defined($value) && $value =~ /^\d+$/;
}

# Prueft einen Wert auf eine einfache Ganz- oder Dezimalzahl ohne Exponentenschreibweise.
sub VIOLET_IsNumber {
	my ($value) = @_;
	return defined($value)
		&& $value =~ /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/;
}

1;
