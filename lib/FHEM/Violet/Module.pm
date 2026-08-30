# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;
use HttpUtils;
use JSON::PP qw(decode_json);
use Encode qw(decode encode FB_CROAK);
use utf8 ();
use MIME::Base64 qw(encode_base64);
use Time::HiRes qw(gettimeofday);
use FHEM::Violet::Helpers qw(
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

use FHEM::Violet::Commands;
use FHEM::Violet::Discovery;
use FHEM::Violet::ErrorCodes;
use FHEM::Violet::Logging;
use FHEM::Violet::Readings;
use FHEM::Violet::Transport;

package FHEM::Violet::Module;

use strict;
use warnings;

# Modul-Buildkennung, die in FHEM-Internals zur Pruefung der geladenen Datei erscheint.
our $VERSION = '2026-08-30.1131';

# Verwirft Authentifizierungs- und Discovery-Zustand gemeinsam, sobald Definition,
# Benutzername oder Passwort geaendert wurden.
sub invalidate_session {
	my ($hash) = @_;
	delete $hash->{VIOLET_AUTH_VALIDATED};
	delete $hash->{VIOLET_AUTH_REJECTED};
	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = 0;
	delete $hash->{VIOLET_ACTIVE_PREFIXES};
	delete $hash->{VIOLET_AUTO_QUERY};

	# Bereits erkannte Set-Faehigkeiten gehoeren zum verworfenen Discovery-Zustand.
	delete $hash->{helper}{setCapabilities} if ref($hash->{helper}) eq 'HASH';
	return undef;
}

# Registriert die FHEM-Callbacks, Attribute und den HTTP-Push-Endpunkt des Moduls.
sub initialize {
	my ($hash, $reading_attributes) = @_;

	# Den geladenen Build zur Diagnose in den Modulmetadaten sichtbar machen.
	$hash->{VERSION} = $VERSION;
	$hash->{MODULE_FILE} = '50_Violet.pm';

	# Bei einem Neuladen auch bestehende VIOLET-Geraete kennzeichnen und deren
	# Discovery-Cache verwerfen, damit geaenderte Zuordnungen sofort wirksam werden.
	for my $dev_name (keys %main::defs) {
		my $device = $main::defs{$dev_name};
		next if !$device || uc($device->{TYPE} // '') ne 'VIOLET';
		$device->{VERSION} = $VERSION;
		$device->{MODULE_FILE} = '50_Violet.pm';
		$device->{VIOLET_CONFIG_DISCOVERED_AT} = 0;
	}

	$hash->{DefFn}    = 'VIOLET_Define';
	$hash->{UndefFn}  = 'VIOLET_Undef';
	$hash->{SetFn}    = 'VIOLET_Set';
	$hash->{GetFn}    = 'VIOLET_Get';
	$hash->{AttrFn}   = 'VIOLET_Attr';
	$hash->{NotifyFn} = 'VIOLET_Notify';

	# Die kontextbezogene FHEMWEB-Hilfe erscheint erst nach Auswahl eines Eintrags.
	$hash->{FW_deviceOverview} = 1;
	$hash->{AttrList} =
			'interval '
		. 'readingsQuery '
		. 'useSSL:0,1 '
		. 'port '
		. 'username '
		. 'token '
		. 'timeout '
		. 'disable:0,1 '
		. ($reading_attributes // '');

	# Den unsichtbaren FHEMWEB-Endpunkt fuer Push-Meldungen der Steuerung registrieren.
	$main::data{FWEXT}{'/VIOLET'}{FUNC} = 'VIOLET_Push';
	return undef;
}

# Liest Benutzername und gespeichertes Passwort, ohne den Geraetezustand zu aendern.
# AttrFn kann den noch nicht uebernommenen Benutzernamen explizit uebergeben.
sub credentials_info {
	my ($hash, $user_override) = @_;
	my $name = $hash->{NAME};
	my $user = defined($user_override)
		? $user_override
		: main::AttrVal($name, 'username', '');
	my ($storage_error, $password) = main::getKeyValue('VIOLET_PASSWORD_'.$name);

	# Ein noch nicht gespeichertes Passwort wird intern als leerer Wert behandelt.
	$password = '' if !defined $password;
	return ($user, $password, $storage_error);
}

# Liefert nur dann wahr, wenn beide Zugangsdaten vorhanden sind und der letzte
# Anmeldeversuch nicht abgelehnt wurde.
sub credentials_ready {
	my ($hash, $user_override) = @_;
	my ($user, $password, $storage_error) = credentials_info($hash, $user_override);

	# Speicherfehler und unvollstaendige oder abgelehnte Daten verhindern HTTP-Aufrufe.
	return 0 if defined($storage_error) && $storage_error ne '';
	return 0 if $user eq '' || $password eq '';
	return 0 if $hash->{VIOLET_AUTH_REJECTED};
	return 1;
}

# Aktualisiert den sichtbaren Authentifizierungs- und Geraetezustand, ohne selbst
# einen Netzwerkaufruf oder Poll-Timer zu starten.
sub update_credential_state {
	my ($hash, $user_override) = @_;
	my ($user, $password, $storage_error) = credentials_info($hash, $user_override);

	my $auth_state;

	# KeyValueStore-Fehler von fehlenden und abgelehnten Zugangsdaten unterscheiden.
	if (defined($storage_error) && $storage_error ne '') {
		$auth_state = 'storage_error';
	} elsif ($user eq '') {
		$auth_state = 'missing_username';
	} elsif ($password eq '') {
		$auth_state = 'missing_password';
	} elsif ($hash->{VIOLET_AUTH_REJECTED}) {
		$auth_state = 'rejected';
	} else {
		$auth_state = $hash->{VIOLET_AUTH_VALIDATED} ? 'accepted' : 'configured';
	}

	main::readingsBeginUpdate($hash);
	main::VIOLET_BulkUpdateReading($hash, 'authUser', $user, 0, 0);
	main::VIOLET_BulkUpdateReading($hash, 'authState', $auth_state, 0, 0);

	# Vor einem erfolgreichen authentifizierten Aufruf nie connected anzeigen.
	if (!$hash->{VIOLET_AUTH_VALIDATED}) {
		my %state_for = (
			storage_error     => 'storage_error',
			missing_username  => 'missing_username',
			missing_password  => 'missing_password',
			rejected          => 'auth_rejected',
			configured        => 'authenticating',
		);
		my $state = $state_for{$auth_state} // 'credentials_required';
		main::VIOLET_BulkUpdateReading($hash, 'connection', $state, 0, 0);
		main::VIOLET_BulkUpdateReading($hash, 'state', $state, 1, 0);
	}
	main::readingsEndUpdate($hash, 1);
	return $auth_state;
}

# Definiert ein VIOLET-Geraet und wartet mit dem ersten API-Aufruf, bis FHEM
# Attribute und gespeicherte Zugangsdaten wiederhergestellt hat.
sub define {
	my ($hash, $definition) = @_;
	main::VIOLET_LogCall($hash, 'VIOLET_Define', $definition);
	my @parts = split(/[ \t]+/, $definition);

	# Nur die feste Definition aus Geraetename, Modultyp und Zielhost akzeptieren.
	return 'Usage: define <name> VIOLET <host-or-ip>' if @parts != 3;

	my (undef, undef, $host) = @parts;
	$hash->{HOST} = $host;
	$hash->{VERSION} = $VERSION;
	$hash->{MODULE_FILE} = '50_Violet.pm';
	$hash->{NOTIFYDEV} = 'global';
	$hash->{STATE} = 'credentials_required';

	# Define kontaktiert VIOLET nie und erzeugt ohne Zugangsdaten keinen Poll-Timer.
	main::RemoveInternalTimer($hash);
	invalidate_session($hash);
	update_credential_state($hash);
	return undef;
}

# Entfernt beim Loeschen des Geraets dessen Poll-Timer aus der FHEM-Runtime.
sub undefine {
	my ($hash, $argument) = @_;
	main::VIOLET_LogCall($hash, 'VIOLET_Undef', $argument);
	main::RemoveInternalTimer($hash);
	return undef;
}

# Bewertet die Zugangsdaten nach INITIALIZED oder REREADCFG erneut, damit alte
# Statefile-Readings den aktuellen Authentifizierungszustand nicht verdecken.
sub notify {
	my ($hash, $device) = @_;
	main::VIOLET_LogCall(
		$hash,
		'VIOLET_Notify',
		($device && $device->{NAME}) ? $device->{NAME} : '<unknown>',
	);

	# Nur globale Lifecycle-Ereignisse sind fuer den Neustart des Pollings relevant.
	return undef if !$hash || !$device || ($device->{NAME} // '') ne 'global';

	my $events = main::deviceEvents($device, 1);
	return undef if !ref($events);

	my $relevant = 0;

	# In der Ereignisliste nach vollstaendiger Initialisierung oder rereadcfg suchen.
	for my $event (@$events) {
		next if !defined $event;

		# Das erste passende Lifecycle-Ereignis reicht fuer die erneute Bewertung aus.
		if ($event eq 'INITIALIZED' || $event eq 'REREADCFG') {
			$relevant = 1;
			last;
		}
	}

	return undef if !$relevant;

	# Mit sauberem Timer- und Authentifizierungszustand in die neue Runtime starten.
	main::RemoveInternalTimer($hash);
	delete $hash->{VIOLET_AUTH_VALIDATED};
	delete $hash->{VIOLET_AUTH_REJECTED};
	update_credential_state($hash);

	# Gespeicherte Zugangsdaten duerfen Polling erst nach der Initialisierung starten.
	main::VIOLET_SchedulePoll($hash, 1) if credentials_ready($hash);
	return undef;
}

# Validiert Laufzeitattribute und erneuert bei relevanten Aenderungen den
# Authentifizierungs- beziehungsweise Polling-Zustand des Geraets.
sub attr {
	my ($definitions, $command, $name, $attribute, $value) = @_;
	my $hash = $definitions->{$name};

	# Attribute unbekannter oder bereits geloeschter Geraete werden ignoriert.
	return undef if !$hash;

	# Das Push-Token ist geheim und wird nie ins Log geschrieben.
	my $log_value = lc($attribute // '') eq 'token'
		? '<redacted>'
		: (defined($value) ? $value : '<undef>');
	main::VIOLET_LogCall($hash, 'VIOLET_Attr', $command, $attribute, $log_value);

	# Polling-Intervalle duerfen nur 0 oder mindestens fuenf Sekunden betragen.
	if ($attribute eq 'interval' && $command eq 'set') {
		return 'interval must be 0 or an integer >= 5 seconds'
			if $value !~ /^\d+$/ || ($value != 0 && $value < 5);
	}

	# Einen ausdruecklich konfigurierten TCP-Port gegen den gueltigen Bereich pruefen.
	if ($attribute eq 'port' && $command eq 'set') {
		return 'port must be 1..65535'
			if $value !~ /^\d+$/ || $value < 1 || $value > 65535;
	}

	# HTTP-Zeitueberschreitung als positiven Zahlenwert pruefen.
	if ($attribute eq 'timeout' && $command eq 'set') {
		return 'timeout must be a positive number'
			if $value !~ /^\d+(?:\.\d+)?$/ || $value <= 0;
	}

	# Eine manuelle readingsQuery vor der Uebernahme gegen bekannte Gruppen pruefen.
	if ($attribute eq 'readingsQuery' && $command eq 'set') {
		my $error = main::VIOLET_ValidateValueGroups(split(/,/, $value));
		return $error if defined $error;
	}

	# Ein geaenderter Benutzername verwirft die bisherige Authentifizierung und nutzt
	# den neuen Wert bereits waehrend der noch laufenden FHEM-Attributaenderung.
	if ($attribute eq 'username') {
		my $user = $command eq 'set' ? $value : '';
		invalidate_session($hash);
		main::RemoveInternalTimer($hash);
		update_credential_state($hash, $user);

		# Polling nur mit neuem Benutzer und bereits gespeichertem Passwort starten.
		if (credentials_ready($hash, $user)) {
			main::VIOLET_SchedulePoll($hash, 1, $user);
		}
	}

	# Poll-Timer nach Aenderungen an interval/disable kontrolliert neu aufbauen.
	if ($attribute eq 'interval' || $attribute eq 'disable') {
		main::RemoveInternalTimer($hash);

		# Nur gültige Attributoperationen mit weiterhin vollständigen Zugangsdaten planen.
		if (($command eq 'set' || $command eq 'del') && credentials_ready($hash)) {
			main::VIOLET_SchedulePoll($hash, 1);
		}
	}
	return undef;
}

1;
