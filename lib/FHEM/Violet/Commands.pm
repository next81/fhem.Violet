# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;
use vars qw(%VIOLET_CHEM %VIOLET_TARGET);

# Befehlsauswertung, Befehlslisten und schreibende VIOLET-API-Helfer.
# Die Implementierung bleibt im Paket main, damit FHEM-Callbacks und Kernhelfer
# ohne Adapter- oder Namensänderungen verwendet werden können.

# Zentrale Zuordnung aller Chemiekanäle. Jeder öffentliche FHEM-Name existiert nur
# einmal; endpunktspezifische VIOLET-Kennungen stehen als Eigenschaften, statt in
# getrennten Dosier-, Kanister- und Konfigurationstabellen wiederholt zu werden.
our %VIOLET_CHEM = (
	chlor => {
		output       => 'DOS_1_CL',
		doseIndex    => 0,
		canisterId   => 1,
		configPrefix => 'DOSAGE_chlorine',
	},
	electrolysis => {
		output       => 'DOS_2_ELO',
		doseIndex    => 1,
		canisterId   => 2,
		configPrefix => 'DOSAGE_electrolysis',
	},
	phminus => {
		output       => 'DOS_4_PHM',
		doseIndex    => 3,
		canisterId   => 4,
		configPrefix => 'DOSAGE_phminus',
	},
	phplus => {
		output       => 'DOS_5_PHP',
		doseIndex    => 4,
		canisterId   => 5,
		configPrefix => 'DOSAGE_phplus',
	},
	floc => {
		output       => 'DOS_6_FLOC',
		doseIndex    => 5,
		canisterId   => 6,
		configPrefix => 'DOSAGE_floc',
	},
	h2o2 => {
		configPrefix => 'DOSAGE_h2o2',
	},
);

# Sollwert-Metadaten stehen in einer Tabelle, damit Set-Prüfung und Normalisierung
# der Reading-Namen denselben echten VIOLET-Konfigurationsschlüssel verwenden.
our %VIOLET_TARGET = (
	ph => {
		configKey => 'DOSAGE_phminus_setpoint',
		min       => 6.0,
		max       => 8.0,
		canonical => 'PH_TARGET',
	},
	orp => {
		configKey => 'DOSAGE_chlorine_setpoint_orp',
		min       => 500,
		max       => 900,
		canonical => 'ORP_TARGET',
	},
	minchlorine => {
		configKey => 'DOSAGE_chlorine_lowerval_cl',
		min       => 0.0,
		max       => 5.0,
		canonical => 'CHLOR_MIN_TARGET',
	},
	heater => {
		configKey => 'HEATER_set_temp',
		min       => 5.0,
		max       => 45.0,
		canonical => 'HEATER_TARGET',
	},
	solar => {
		configKey => 'SOLAR_maxtemp',
		min       => 5.0,
		max       => 55.0,
		canonical => 'SOLAR_TARGET',
	},
);

# Lokale unveränderliche Momentaufnahme für Optionen und Nutzungshinweise.
# Dienstzuordnung und Endpunktaufbau liegen im nebenwirkungsfreien Hilfsmodul.
my @VIOLET_SERVICES = VIOLET_ServiceNames();

# Validiert und verteilt alle öffentlichen FHEM-Set-Befehle auf sichere API-Aufrufe.
sub VIOLET_Set($@) {
	my ($hash, @a) = @_;
	my $name = shift @a;
	return VIOLET_SetUsage($hash) if !@a;
	my $cmd = lc(shift @a);

	# Passwortargumente vor der Funktionsprotokollierung auf Stufe 4 schwärzen.
	my @logArgs = $cmd eq 'password' ? ('password', '<redacted>') : ($cmd, @a);
	VIOLET_LogCall($hash, 'VIOLET_Set', @logArgs);

	# Das Passwort liegt im FHEM-KeyValueStore, der Benutzername bleibt ein normales
	# Geräteattribut. Es gibt bewusst keine besondere Aktion "clear".
	if ($cmd eq 'password') {
		return 'Usage: set '.$name.' password <password>' if !@a;
		my $password = join(' ', @a);
		return 'password must not be empty' if $password eq '';
		my ($err) = setKeyValue('VIOLET_PASSWORD_'.$name, $password);

		# Bei einem Schreibfehler des KeyValueStore abbrechen, damit FHEM nie
		# konfigurierte Zugangsdaten meldet, obwohl das Passwort nicht gespeichert wurde.
		if (defined($err) && $err ne '') {
			VIOLET_Log($hash, 1, 'critical KeyValueStore write error: '.VIOLET_LogValue($err));
			VIOLET_SingleUpdateReading($hash, 'authState', 'storage_error', 0, 0);
			return 'error while saving password: '.$err;
		}
		my $user = AttrVal($name, 'username', '');

		# Ein neues Passwort verwirft das bisherige Anmeldeergebnis und erzwingt nach
		# erfolgreicher Authentifizierung eine neue Konfigurationserkennung.
		VIOLET_InvalidateSession($hash);

		RemoveInternalTimer($hash);
		VIOLET_UpdateCredentialState($hash);

		# Ein Passwort allein reicht nicht. Polling nur mit Benutzername starten.
		if ($user ne '' && VIOLET_CredentialsReady($hash)) {
			VIOLET_Log($hash, 2, 'credentials complete; polling will start');
			VIOLET_SchedulePoll($hash, 1);
		} else {
			VIOLET_Log($hash, 2, 'password stored; waiting for username before polling');
		}
		return undef;
	}

	# FHEMWEB-freundliche Direktbefehle für mehrstufige Set-Syntax. Da FHEMWEB je
	# Set-Befehl ein Widget zuordnet, werden häufige Unterbefehle als Aliase
	# angeboten; die kompakte CLI-Syntax bleibt unterstützt.
	# Sollwert-Aliase wie targetPh erkennen und den Wert vor dem Senden in der
	# gemeinsamen Sollwertfunktion prüfen.
	if ($cmd =~ /^target(ph|orp|minchlorine|heater|solar)$/) {
		return 'value is required' if @a != 1;
		return VIOLET_SetTarget($hash, $1, $a[0]);
	}

	# FHEMWEB-Aliase ext1_1..ext2_8 für Erweiterungsrelais erkennen und Aktionen
	# auf die von der Steuerung unterstützten Zustände on/off/auto beschränken.
	if ($cmd =~ /^ext([12])_([1-8])$/) {
		my ($bank, $relay) = ($1, $2);
		return 'action must be on, off or auto' if @a != 1 || lc($a[0]) !~ /^(?:on|off|auto)$/;
		return VIOLET_SetFunction($hash, 'EXT'.$bank.'_'.$relay, uc($a[0]), 0, 0);
	}

	# FHEMWEB-DMX-Aliase dmx1..dmx12 erkennen und die gewählte Aktion prüfen.
	if ($cmd =~ /^dmx(1[0-2]|[1-9])$/) {
		my $scene = $1;
		return 'action must be on, off or auto' if @a != 1 || lc($a[0]) !~ /^(?:on|off|auto)$/;
		return VIOLET_SetFunction($hash, 'DMX_SCENE'.$scene, uc($a[0]), 0, 0);
	}

	# FHEMWEB-Aliase für Digitaleingangsregeln erkennen; nur push/lock/unlock erlauben.
	if ($cmd =~ /^dirule([1-7])$/) {
		my $rule = $1;
		return 'action must be push, lock or unlock' if @a != 1 || lc($a[0]) !~ /^(?:push|lock|unlock)$/;
		return VIOLET_SetFunction($hash, 'DIRULE_'.$rule, uc($a[0]), 0, 0);
	}

	# Direkte Aliase für manuelle Dosierung erkennen, eine positive Dauer verlangen
	# und VIOLET-Ausgang/-Index ausschließlich über die Chemietabelle bestimmen.
	if ($cmd =~ /^dose(chlor|electrolysis|phminus|phplus|floc)$/) {
		return 'seconds must be a positive integer' if @a != 1 || !VIOLET_IsUInt($a[0]) || $a[0] < 1;
		my $type = $1;
		my $chem = $VIOLET_CHEM{$type};
		my ($dkey, $idx) = @{$chem}{qw(output doseIndex)};
		return VIOLET_ManualDosing($hash, $dkey, $idx, 'DOSSTART', $a[0]);
	}

	# Direkte Dosierstopp-Aliase erkennen und dieselbe zentrale Chemietabelle wie
	# beim Starten einer Dosierung verwenden.
	if ($cmd =~ /^dosestop(chlor|electrolysis|phminus|phplus|floc)$/) {
		return 'Usage: set '.$name.' '.$cmd if @a;
		my $type = $1;
		my $chem = $VIOLET_CHEM{$type};
		my ($dkey, $idx) = @{$chem}{qw(output doseIndex)};
		return VIOLET_ManualDosing($hash, $dkey, $idx, 'DOSSTOP', 0);
	}

	# FHEMWEB bietet je Chemiekanal einen eindeutigen Befehl an, etwa
	# dosageChlor:start,stop. Er steuert das dauerhafte Konfigurationsmerkmal
	# DOSAGE_*_use und bleibt bewusst von der manuellen Dosierung getrennt.
	if ($cmd =~ /^dosage(chlor|electrolysis|phminus|phplus|floc|h2o2)$/) {
		my $type = $1;
		return 'state must be start or stop'
			if @a != 1 || lc($a[0]) !~ /^(?:start|stop)$/;
		my $state = lc($a[0]);
		my $key = $VIOLET_CHEM{$type}{configPrefix}.'_use';
		return VIOLET_WriteConfig(
			$hash,
			{ $key => ($state eq 'start' ? 1 : 0) },
			"dosage $type $state"
		);
	}

	# Frühere Direktnamen dosageEnable<Type> als CLI-Kompatibilitätsaliase behalten,
	# aber nicht mehr in FHEMWEB anbieten.
	if ($cmd =~ /^dosageenable(chlor|electrolysis|phminus|phplus|floc|h2o2)$/) {
		my $type = $1;
		return 'state must be on or off' if @a != 1 || lc($a[0]) !~ /^(?:on|off)$/;
		my $key = $VIOLET_CHEM{$type}{configPrefix}.'_use';
		return VIOLET_WriteConfig(
			$hash,
			{ $key => (lc($a[0]) eq 'on' ? 1 : 0) },
			"dosageEnable $type ".lc($a[0])
		);
	}

	# Direkte Kanister-Aliase erkennen und eine positive Millilitermenge verlangen.
	if ($cmd =~ /^canister(chlor|electrolysis|phminus|phplus|floc)(adjust|reset)$/) {
		return 'ml must be a positive integer' if @a != 1 || !VIOLET_IsUInt($a[0]) || $a[0] < 1;
		return VIOLET_SetCanister($hash, $1, $a[0], $2);
	}

	# Direkten FHEMWEB-Dienstbefehl über die zentrale Dienstliste auflösen und den
	# enable/disable-Endpunkt erst nach Prüfung des gewünschten Zustands bilden.
	if (my $service = VIOLET_ServiceFromSetCommand($cmd)) {
		return 'state must be on or off' if @a != 1 || lc($a[0]) !~ /^(?:on|off)$/;
		my $state = lc($a[0]);
		my $path = VIOLET_ServicePath($service, $state);
		return VIOLET_Request($hash, method=>'GET', path=>$path, purpose=>"service $service $state", refresh=>0);
	}

	# Aliase zur Wiederherstellung der Kalibrierung erkennen und den öffentlichen
	# Namen chlor in VIOLETs interne Sensorbezeichnung "pot" übersetzen.
	if ($cmd =~ /^calibrationrestore(ph|orp|chlor)$/) {
		return 'unixTimestamp must be a positive integer' if @a != 1 || !VIOLET_IsUInt($a[0]) || $a[0] < 1;
		my $which = $1 eq 'chlor' ? 'pot' : $1;
		return VIOLET_Request($hash, method=>'POST', path=>'/restoreOldCalib',
			data=>VIOLET_FormEncode({calDate=>$a[0], which=>$which}),
			contentType=>'application/x-www-form-urlencoded', purpose=>'calibrationRestore '.$which.' '.$a[0], refresh=>1);
	}

	# Normale Steuerungsausgänge behandeln. Vor der Zuordnung des öffentlichen
	# Befehls zu einem VIOLET-Schlüssel Aktion, Dauer und Pumpenstufe prüfen.
	if ($cmd =~ /^(pump|solar|heater|eco|backwash|rinse|refill)$/) {
		return 'Usage: set '.$name.' '.$cmd.' <on|off|auto> [durationSec] [speed]'
			if !@a;
		my $action = uc(shift @a);
		return 'action must be on, off or auto' if $action !~ /^(ON|OFF|AUTO)$/;
		my $duration = @a ? shift @a : 0;
		return 'durationSec must be a non-negative integer' if !VIOLET_IsUInt($duration);
		my $speed = @a ? shift @a : 0;
		return 'speed must be 0..3' if $speed !~ /^\d+$/ || $speed < 0 || $speed > 3;
		return 'too many arguments' if @a;

		my %map = (
			pump     => 'PUMP',
			solar    => 'SOLAR',
			heater   => 'HEATER',
			eco      => 'ECO',
			backwash => 'BACKWASH',
			rinse    => 'BACKWASHRINSE',
			refill   => 'REFILL',
		);
		return VIOLET_SetFunction($hash, $map{$cmd}, $action, $duration, $speed);
	}

	# Eigenen Kurzbefehl für Pumpenstufe 1..3 und optionale Laufzeit prüfen.
	if ($cmd eq 'pumpspeed') {
		return 'Usage: set '.$name.' pumpSpeed <1|2|3> [durationSec]' if !@a;
		my $speed = shift @a;
		my $duration = @a ? shift @a : 0;
		return 'speed must be 1..3' if $speed !~ /^[123]$/;
		return 'durationSec must be a non-negative integer' if !VIOLET_IsUInt($duration);
		return 'too many arguments' if @a;
		return VIOLET_SetFunction($hash, 'PUMP', 'ON', $duration, $speed);
	}

	# Lichtsteuerung auf VIOLETs Aktionen on/off/auto/color beschränken.
	if ($cmd eq 'light') {
		return 'Usage: set '.$name.' light <on|off|auto|color>' if !@a;
		my $action = uc(shift @a);
		return 'light action must be on, off, auto or color'
			if $action !~ /^(ON|OFF|AUTO|COLOR)$/;
		return 'too many arguments' if @a;
		return VIOLET_SetFunction($hash, 'LIGHT', $action, 0, 0);
	}

	# PV-Überschusssteuerung prüfen; anders als bei normaler Pumpensteuerung
	# transportiert VIOLET die optionale Stufe in value1 statt value2.
	if ($cmd eq 'pvsurplus') {
		return 'Usage: set '.$name.' pvSurplus <on|off> [speed 1..3]' if !@a;
		my $action = uc(shift @a);
		return 'pvSurplus supports only on/off' if $action !~ /^(ON|OFF)$/;
		my $speed = @a ? shift @a : 0;
		return 'speed must be 0..3' if $speed !~ /^\d+$/ || $speed < 0 || $speed > 3;
		return 'too many arguments' if @a;
		# VIOLET nutzt WERT_1 für die PV-Pumpenstufe, PUMP dagegen WERT_2.
		return VIOLET_SetFunctionRaw($hash, 'PVSURPLUS', $action, $speed, 0);
	}

	# Generische Erweiterungsrelais-Syntax prüfen: Bank 1..2, Relais 1..8, Aktion
	# und optionale nichtnegative Dauer.
	if ($cmd eq 'ext') {
		return 'Usage: set '.$name.' ext <1|2> <1..8> <on|off|auto> [durationSec]' if @a < 3;
		my ($bank, $relay, $action) = splice(@a, 0, 3);
		$action = uc($action);
		my $duration = @a ? shift @a : 0;
		return 'extension bank must be 1 or 2' if $bank !~ /^[12]$/;
		return 'relay must be 1..8' if $relay !~ /^[1-8]$/;
		return 'action must be on, off or auto' if $action !~ /^(ON|OFF|AUTO)$/;
		return 'durationSec must be a non-negative integer' if !VIOLET_IsUInt($duration);
		return 'too many arguments' if @a;
		return VIOLET_SetFunction($hash, "EXT${bank}_${relay}", $action, $duration, 0);
	}

	# Generische DMX-Szenenauswahl 1..12 und Aktion prüfen.
	if ($cmd eq 'dmx') {
		return 'Usage: set '.$name.' dmx <1..12> <on|off|auto>' if @a != 2;
		my ($scene, $action) = @a;
		$action = uc($action);
		return 'scene must be 1..12' if $scene !~ /^\d+$/ || $scene < 1 || $scene > 12;
		return 'action must be on, off or auto' if $action !~ /^(ON|OFF|AUTO)$/;
		return VIOLET_SetFunction($hash, 'DMX_SCENE'.$scene, $action, 0, 0);
	}

	# Öffentliche Aktion für alle Szenen in VIOLETs ALLON/ALLOFF/ALLAUTO übersetzen.
	if ($cmd eq 'dmxall') {
		return 'Usage: set '.$name.' dmxAll <on|off|auto>' if @a != 1;
		my %act = ( on => 'ALLON', off => 'ALLOFF', auto => 'ALLAUTO' );
		my $action = $act{lc($a[0])};
		return 'action must be on, off or auto' if !$action;
		return VIOLET_SetFunction($hash, 'DMX_SCENE1', $action, 0, 0);
	}

	# Nummer der Digitaleingangsregel und erlaubte Aktion push/lock/unlock prüfen.
	if ($cmd eq 'dirule') {
		return 'Usage: set '.$name.' diRule <1..8> <push|lock|unlock>' if @a != 2;
		my ($rule, $action) = @a;
		$action = uc($action);
		return 'rule must be 1..8' if $rule !~ /^[1-8]$/;
		return 'action must be push, lock or unlock' if $action !~ /^(PUSH|LOCK|UNLOCK)$/;
		return VIOLET_SetFunction($hash, 'DIRULE_'.$rule, $action, 0, 0);
	}

	# Generische Sollwertsyntax behandeln; Zahlen- und Bereichsprüfungen liegen
	# zentral in VIOLET_SetTarget, damit Aliase und CLI identisch arbeiten.
	if ($cmd eq 'target') {
		return 'Usage: set '.$name.' target <ph|orp|minChlorine|heater|solar> <value>' if @a != 2;
		return VIOLET_SetTarget($hash, $a[0], $a[1]);
	}


	# Generische manuelle Dosierung behandeln. Nur Kanäle mit output und doseIndex
	# in %VIOLET_CHEM sind zulässig; h2o2 kann sie nicht versehentlich verwenden.
	if ($cmd eq 'dose' || $cmd eq 'dosestop') {
		return 'Usage: set '.$name.' '.$cmd.' <chlor|electrolysis|phminus|phplus|floc> '.($cmd eq 'dose' ? '<seconds>' : '')
			if !@a;
		my $type = lc(shift @a);
		return 'unknown dosing type' if !exists($VIOLET_CHEM{$type}) || !defined($VIOLET_CHEM{$type}{output});
		my $chem = $VIOLET_CHEM{$type};
		my ($dkey, $idx) = @{$chem}{qw(output doseIndex)};
		my $seconds = 0;

		# Ein Dosierstart braucht eine positive Dauer; doseStop belässt die Laufzeit
		# bewusst bei null und sendet stattdessen DOSSTOP.
		if ($cmd eq 'dose') {
			return 'duration in seconds is required' if !@a;
			$seconds = shift @a;
			return 'seconds must be a positive integer' if !VIOLET_IsUInt($seconds) || $seconds < 1;
		}
		return 'too many arguments' if @a;
		return VIOLET_ManualDosing($hash, $dkey, $idx, $cmd eq 'dose' ? 'DOSSTART' : 'DOSSTOP', $seconds);
	}

	# Konfigurierten Chemiekanal über seinen zentralen configPrefix ein-/ausschalten.
	if ($cmd eq 'dosageenable') {
		return 'Usage: set '.$name.' dosageEnable <chlor|electrolysis|phminus|phplus|floc|h2o2> <on|off>' if @a != 2;
		my ($type, $onoff) = (lc($a[0]), lc($a[1]));
		return 'unknown dosing type' if !exists($VIOLET_CHEM{$type}) || !defined($VIOLET_CHEM{$type}{configPrefix});
		return 'state must be on or off' if $onoff !~ /^(on|off)$/;
		my $key = $VIOLET_CHEM{$type}{configPrefix}.'_use';
		return VIOLET_WriteConfig($hash, { $key => ($onoff eq 'on' ? 1 : 0) }, "dosageEnable $type $onoff");
	}

	# Generische Kanistersyntax prüfen und endpunktspezifische Kennungen an
	# VIOLET_SetCanister sowie die zentrale Chemietabelle delegieren.
	if ($cmd eq 'canister') {
		return 'Usage: set '.$name.' canister <chlor|electrolysis|phminus|phplus|floc> <ml> <adjust|reset>' if @a != 3;
		my ($type, $ml, $action) = (lc($a[0]), $a[1], lc($a[2]));
		return 'unknown canister type' if $type !~ /^(chlor|electrolysis|phminus|phplus|floc)$/;
		return 'ml must be a positive integer' if !VIOLET_IsUInt($ml) || $ml < 1;
		return 'action must be adjust or reset' if $action !~ /^(adjust|reset)$/;
		return VIOLET_SetCanister($hash, $type, $ml, $action);
	}

	# Öffentliche Abdeckungsaktionen auf VIOLETs COVER_*-Push-Funktionen abbilden.
	if ($cmd eq 'cover') {
		return 'Usage: set '.$name.' cover <open|close|stop>' if @a != 1;
		my %map = ( open=>'COVER_OPEN', close=>'COVER_CLOSE', stop=>'COVER_STOP' );
		my $key = $map{lc($a[0])};
		return 'cover action must be open, close or stop' if !$key;
		return VIOLET_SetFunction($hash, $key, 'PUSH', 0, 0);
	}

	# OmniTronic-Positionen auf den unterstützten Bereich 0..5 beschränken.
	if ($cmd eq 'omni') {
		return 'Usage: set '.$name.' omni <0..5>' if @a != 1 || $a[0] !~ /^[0-5]$/;
		return VIOLET_Request($hash, method=>'GET', path=>'/setFunctionManually?OMNI,OMNI_DC'.$a[0].',0,0', purpose=>'omni '.$a[0], refresh=>1);
	}

	# RS485-Pumpen-Livesteuerung prüfen: Slave-Adresse, Regelart und Zahlenwert.
	if ($cmd eq 'rs485live') {
		return 'Usage: set '.$name.' rs485Live <pumpModel> <slaveId 1..247> <rpm|pwr|hz> <level>' if @a != 4;
		my ($model,$slave,$mode,$level) = @a;
		return 'slaveId must be 1..247' if $slave !~ /^\d+$/ || $slave < 1 || $slave > 247;
		return 'mode must be rpm, pwr or hz' if lc($mode) !~ /^(rpm|pwr|hz)$/;
		return 'level must be numeric' if !VIOLET_IsNumber($level);
		my $q = join(',', $model, $slave, lc($mode), $level);
		return VIOLET_Request($hash, method=>'GET', path=>'/setRS485Live?'.$q, purpose=>'rs485Live '.$q, refresh=>0);
	}

	# RS485-Livemodus beenden; dieser Befehl akzeptiert bewusst keine Argumente.
	if ($cmd eq 'rs485done') {
		return 'Usage: set '.$name.' rs485Done' if @a;
		return VIOLET_Request($hash, method=>'GET', path=>'/setRS485Live?DONE', purpose=>'rs485Done', refresh=>0);
	}

	# Dauer des Ausgangstests prüfen und Sekunden in die vom VIOLET-Endpunkt
	# erwarteten Millisekunden umrechnen.
	if ($cmd eq 'outputtest') {
		return 'Usage: set '.$name.' outputTest <output> [mode] [durationSec]' if !@a;
		my $output = shift @a;
		my $mode = @a ? shift @a : 'SWITCH';
		my $duration = @a ? shift @a : 120;
		return 'durationSec must be a non-negative integer' if !VIOLET_IsUInt($duration);
		return 'too many arguments' if @a;
		my $payload = join(',', $output, $mode, $duration * 1000);
		return VIOLET_Request($hash, method=>'GET', path=>'/setOutputTestmode?'.$payload, purpose=>'outputTest '.$payload, refresh=>1);
	}

	# Sensor zur Kalibrierungswiederherstellung und positiven UNIX-Zeitstempel prüfen.
	if ($cmd eq 'calibrationrestore') {
		return 'Usage: set '.$name.' calibrationRestore <ph|orp|pot> <unixTimestamp>' if @a != 2;
		my ($which,$ts) = (lc($a[0]),$a[1]);
		return 'which must be ph, orp or pot' if $which !~ /^(ph|orp|pot)$/;
		return 'unixTimestamp must be a positive integer' if !VIOLET_IsUInt($ts) || $ts < 1;
		return VIOLET_Request($hash, method=>'POST', path=>'/restoreOldCalib',
			data=>VIOLET_FormEncode({calDate=>$ts, which=>$which}),
			contentType=>'application/x-www-form-urlencoded', purpose=>'calibrationRestore '.$which.' '.$ts, refresh=>1);
	}

	# VIOLETs Blockier-/Fehlerzustand zurücksetzen; keine Argumente zulässig.
	if ($cmd eq 'resetblocking') {
		return 'Usage: set '.$name.' resetBlocking' if @a;
		return VIOLET_Request($hash, method=>'GET', path=>'/resetBlocking', purpose=>'resetBlocking', refresh=>1);
	}

	# Generischen Dienstnamen gegen dieselbe zentrale Liste wie FHEMWEB prüfen und
	# den Endpunkt ableiten, statt enable/disable-URLs doppelt zu speichern.
	if ($cmd eq 'service') {
		my $services = join('|', @VIOLET_SERVICES);
		return 'Usage: set '.$name.' service <'.$services.'> <on|off>' if @a != 2;
		my ($service,$state) = (lc($a[0]),lc($a[1]));
		return 'unknown service' if !VIOLET_ServiceExists($service);
		return 'state must be on or off' if $state !~ /^(on|off)$/;
		my $path = VIOLET_ServicePath($service, $state);
		return VIOLET_Request($hash, method=>'GET', path=>$path, purpose=>"service $service $state", refresh=>0);
	}

	# VIOLET-Firmwareaktualisierung starten; keine Argumente zulässig.
	if ($cmd eq 'firmwareupdate') {
		return 'Usage: set '.$name.' firmwareUpdate' if @a;
		return VIOLET_Request($hash, method=>'GET', path=>'/initUpdate', purpose=>'firmwareUpdate', refresh=>0);
	}

	# Steuerung neu starten; keine Argumente zulässig.
	if ($cmd eq 'reboot') {
		return 'Usage: set '.$name.' reboot' if @a;
		return VIOLET_Request($hash, method=>'GET', path=>'/reboot', purpose=>'reboot', refresh=>0);
	}

	# Steuerungsspezifische Wiederherstellungsabfrage an den lokalen Endpunkt weitergeben.
	if ($cmd eq 'localrestore') {
		return 'Usage: set '.$name.' localRestore <controller-query>' if !@a;
		my $query = join(' ', @a);
		return VIOLET_Request($hash, method=>'GET', path=>'/doLocalRestore?'.$query, purpose=>'localRestore', refresh=>0);
	}

	# Lokale manuelle Sicherung auslösen; keine Argumente zulässig.
	if ($cmd eq 'manualbackup') {
		return 'Usage: set '.$name.' manualBackup' if @a;
		return VIOLET_Request($hash, method=>'GET', path=>'/doManualBackup', purpose=>'manualBackup', refresh=>0);
	}

	# Ein LAN-Konfigurationspaar aus Schlüssel und Wert über /setLanConfig schreiben.
	if ($cmd eq 'network') {
		return 'Usage: set '.$name.' network <NET_key> <value>' if @a < 2;
		my $key = shift @a;
		my $value = join(' ', @a);
		return VIOLET_Request($hash, method=>'POST', path=>'/setLanConfig',
			data=>VIOLET_FormEncode({$key=>$value}), contentType=>'application/x-www-form-urlencoded',
			purpose=>'network '.$key, refresh=>0);
	}

	# JSON-Objekt vor dem Schreiben mehrerer LAN-Konfigurationswerte lesen und prüfen.
	if ($cmd eq 'networkjson') {
		return 'Usage: set '.$name.' networkJson <JSON-object>' if !@a;
		my $json = join(' ', @a);
		my $obj = eval { decode_json($json) };
		return 'invalid JSON object: '.$@ if $@ || ref($obj) ne 'HASH';
		return VIOLET_Request($hash, method=>'POST', path=>'/setLanConfig',
			data=>VIOLET_FormEncode($obj), contentType=>'application/x-www-form-urlencoded',
			purpose=>'networkJson', refresh=>0);
	}

	# Genau eine Zeitzone verlangen und als NET_tz weitergeben.
	if ($cmd eq 'timezone') {
		return 'Usage: set '.$name.' timezone <timezone>' if @a != 1;
		return VIOLET_Request($hash, method=>'POST', path=>'/setTimezone',
			data=>VIOLET_FormEncode({NET_tz=>$a[0]}), contentType=>'application/x-www-form-urlencoded',
			purpose=>'timezone '.$a[0], refresh=>0);
	}

	# Generischer Funktionsrückfall: Missbrauch von DOS_* wegen anderem Endpunkt
	# verhindern und vor der Weitergabe Zahlenwerte für value1/value2 verlangen.
	if ($cmd eq 'function') {
		return 'Usage: set '.$name.' function <outputKey> <action> [value1] [value2]' if @a < 2;
		my ($key,$action) = splice(@a,0,2);
		return 'DOS_* outputs must use dose/doseStop (different endpoint)' if $key =~ /^DOS_/i;
		my $v1 = @a ? shift @a : 0;
		my $v2 = @a ? shift @a : 0;
		return 'value1 must be numeric' if !VIOLET_IsNumber($v1);
		return 'value2 must be numeric' if !VIOLET_IsNumber($v2);
		return 'too many arguments' if @a;
		return VIOLET_SetFunctionRaw($hash, $key, uc($action), $v1, $v2);
	}

	# Raw-GET-Rückfall akzeptiert nur absolute API-Pfade, die mit "/" beginnen.
	if ($cmd eq 'rawget') {
		return 'Usage: set '.$name.' rawGet </path?query>' if !@a;
		my $path = join(' ', @a);
		return 'path must start with /' if $path !~ m{^/};
		return VIOLET_Request($hash, method=>'GET', path=>$path, purpose=>'rawGet '.$path, refresh=>0);
	}

	# Raw-POST-Rückfall akzeptiert nur absolute API-Pfade, die mit "/" beginnen.
	if ($cmd eq 'rawpost') {
		return 'Usage: set '.$name.' rawPost </path> <form-data>' if @a < 2;
		my $path = shift @a;
		my $body = join(' ', @a);
		return 'path must start with /' if $path !~ m{^/};
		return VIOLET_Request($hash, method=>'POST', path=>$path, data=>$body,
			contentType=>'application/x-www-form-urlencoded', purpose=>'rawPost '.$path, refresh=>0);
	}

	return VIOLET_SetUsage($hash);
}

# Validiert und verteilt alle öffentlichen FHEM-Get-Befehle auf ihre Lese-Endpunkte.
sub VIOLET_Get($@) {
	my ($hash, @a) = @_;
	my $name = shift @a;
	return VIOLET_GetUsage() if !@a;
	my $cmd = lc(shift @a);
	VIOLET_LogCall($hash, 'VIOLET_Get', $cmd, @a);

	# Ohne ausdrückliche Gruppen die automatisch ermittelte Funktionsabfrage nutzen.
	# Das Attribut readingsQuery bleibt eine optionale manuelle Überschreibung.
	if ($cmd eq 'values') {

		# Ohne manuelle Gruppen ausschließlich die optimierte Discovery-Abfrage verwenden.
		if (!@a) {
			return VIOLET_RequestAutoValues($hash, 'getValues');
		}

		# Ausdrückliche Gruppen sind eine Diagnose-/Manuellabfrage. Genau diese Gruppen
		# liefern und den konfigurationsbasierten Aktivfilter nicht anwenden.
		my $err = VIOLET_ValidateValueGroups(@a);
		return $err if defined $err;
		my $query = join(',', map { uc($_) } @a);
		return VIOLET_Request($hash, method=>'GET', path=>'/getReadings?'.$query,
			purpose=>'getValues', parseReadings=>1, activeFilter=>0, refresh=>0);
	}

	# FHEMWEB-Einzelauswahl für eine geprüfte /getReadings-Gruppe.
	if ($cmd eq 'valuesgroup') {
		return 'Usage: get '.$name.' valuesGroup <ALL|DOSAGE|RUNTIMES|PUMPPRIOSTATE|BACKWASH|SYSTEM>' if @a != 1;
		my $err = VIOLET_ValidateValueGroups($a[0]);
		return $err if defined $err;
		return VIOLET_Request($hash, method=>'GET', path=>'/getReadings?'.uc($a[0]), purpose=>'getValuesGroup '.uc($a[0]), parseReadings=>1, activeFilter=>0, refresh=>0);
	}

	# Ausgangszustände abrufen und ihre Readings unter output* einordnen.
	if ($cmd eq 'outputs') {
		return VIOLET_Request($hash, method=>'GET', path=>'/getOutputstates', purpose=>'getOutputs', parsePrefix=>'output', refresh=>0);
	}

	# Konfigurations-Get dient nur der Diagnose. Antwort asynchron an den aufrufenden
	# FHEMWEB-/Telnet-Client geben und Konfigurationswerte nie zu Readings machen.
	# Die automatische Erkennung veröffentlicht nur fachliche Sollwerte wie phTarget.
	if ($cmd eq 'config') {
		my $query = @a ? '?'.join(',', @a) : '';
		return VIOLET_Request($hash, method=>'GET', path=>'/getConfig'.$query,
			purpose=>'getConfig', returnBody=>1, refresh=>0);
	}

	# Einen Konfigurationsschlüssel abrufen und nur anzeigen; configKey-Aufrufe
	# verändern auch bei bekannten Sollwerten keine Readings.
	if ($cmd eq 'configkey') {
		return 'Usage: get '.$name.' configKey <KEY>' if @a != 1;
		return VIOLET_Request($hash, method=>'GET', path=>'/getConfig?'.$a[0],
			purpose=>'getConfigKey '.$a[0], returnBody=>1, refresh=>0);
	}

	# Dienstzustände abrufen und unter service* einordnen.
	if ($cmd eq 'services') {
		return VIOLET_Request($hash, method=>'GET', path=>'/getServiceStates', purpose=>'getServices', parsePrefix=>'service', refresh=>0);
	}
	# Metadaten lokaler Sicherungen abrufen und unter backup* einordnen.
	if ($cmd eq 'localbackups') {
		return VIOLET_Request($hash, method=>'GET', path=>'/restoreLocalBackup', purpose=>'getLocalBackups', parsePrefix=>'backup', refresh=>0);
	}
	# Aktualisierungszustand abrufen und unter update* einordnen.
	if ($cmd eq 'updatestate') {
		return VIOLET_Request($hash, method=>'GET', path=>'/getUpdateState', purpose=>'getUpdateState', parsePrefix=>'update', refresh=>0);
	}
	# RS485-Pumpendaten für genau ein Modell abrufen und unter rs485* einordnen.
	if ($cmd eq 'rs485data') {
		return 'Usage: get '.$name.' rs485Data <pumpModel>' if @a != 1;
		return VIOLET_Request($hash, method=>'GET', path=>'/getRS485PumpData?'.$a[0], purpose=>'getRS485Data', parsePrefix=>'rs485', refresh=>0);
	}
	# Raw GET dient nur dem Transport: Pfad prüfen, Antwort aber bewusst weder
	# auswerten noch als Readings speichern.
	if ($cmd eq 'raw') {
		return 'Usage: get '.$name.' raw </path?query>' if !@a;
		my $path = join(' ', @a);
		return 'path must start with /' if $path !~ m{^/};
		# raw dient bewusst nur dem Transport; der Antwortinhalt wird kein FHEM-Reading.
		return VIOLET_Request($hash, method=>'GET', path=>$path, purpose=>'getRaw', refresh=>0);
	}
	return VIOLET_GetUsage();
}

# FHEMWEB-Set-Optionen für die tatsächlich konfigurierten Fähigkeiten liefern.
# Vor der ersten erfolgreichen /getConfig-Erkennung erscheinen nur
# konfigurationsunabhängige Verwaltungsbefehle.
sub VIOLET_SetOptions {
	my ($hash) = @_;
	my $caps = (ref($hash) eq 'HASH' && ref($hash->{helper}) eq 'HASH'
							&& ref($hash->{helper}{setCapabilities}) eq 'HASH')
		? $hash->{helper}{setCapabilities}
		: {};

	my @set = ('password');

	# Diese Funktionen gelten steuerungsweit und hängen nicht von Pool-E/A ab.
	push @set,
		'resetBlocking:noArg', 'outputTest',
		'firmwareUpdate:noArg', 'reboot:noArg', 'manualBackup:noArg', 'localRestore',
		'network', 'networkJson', 'timezone', 'function', 'rawGet', 'rawPost';
	push @set, map { 'service'.VIOLET_ServiceCommandSuffix($_).':on,off' } @VIOLET_SERVICES;

	# Funktionsverfügbarkeit nie vor Auswertung der authentifizierten Konfiguration raten.
	return @set if !$caps->{discovered};
	my $baseOk = !$caps->{baseHardwareChecked} || $caps->{baseHardware};

	# Pumpenbefehle nur für eine konfigurierte beziehungsweise bestätigte Basispumpe anbieten.
	if ($baseOk && $caps->{pump}) {
		push @set, 'pump:on,off,auto';
		push @set, 'pumpSpeed:1,2,3'
			if defined($caps->{pumpType}) && $caps->{pumpType} =~ /^[12]$/;
		push @set, 'rs485Live', 'rs485Done:noArg'
			if defined($caps->{pumpType}) && $caps->{pumpType} eq '2';
	}
	push @set, 'solar:on,off,auto', 'targetSolar:slider,5,0.1,55,1'
		if $baseOk && $caps->{solar};
	push @set, 'heater:on,off,auto', 'targetHeater:slider,5,0.1,45,1'
		if $baseOk && $caps->{heater};
	push @set, 'backwash:on,off,auto', 'rinse:on,off,auto'
		if $baseOk && $caps->{backwash};
	push @set, 'refill:on,off,auto' if $baseOk && $caps->{refill};

	# Den Farbbefehl nur ergänzen, wenn die Lichtkonfiguration Farbwechsel unterstützt.
	if ($baseOk && $caps->{light}) {
		push @set, $caps->{lightColor} ? 'light:on,off,auto,color' : 'light:on,off,auto';
	}
	push @set, 'cover:open,close,stop' if $baseOk && $caps->{cover};
	push @set, 'eco:on,off,auto' if $baseOk && $caps->{eco};
	push @set, 'pvSurplus:on,off' if $baseOk && $caps->{pvSurplus};

	# DMX nur anzeigen, wenn LIGHT_control_dmx es ausdrücklich aktiviert.
	if ($baseOk && $caps->{dmx} && ($caps->{dmxCount} || 0) > 0) {
		push @set, 'dmxAll:on,off,auto';
		push @set, map { "dmx$_:on,off,auto" } 1..$caps->{dmxCount};
	}

	# Erweiterungsrelais sind standardmäßig verborgen. Manche Firmware liefert
	# EXT*-Platzhalter; nur SYSTEM_ext1module_alive_count bzw. ext2 bestätigt die
	# zugehörige physische Erweiterung.
	for my $bank (1,2) {
		next if !$caps->{"ext${bank}HardwareChecked"};
		next if !$caps->{"ext${bank}Hardware"};

		# Nur benannte Relais der nachgewiesenen Erweiterungsbank als Set-Befehl anbieten.
		for my $relay (1..8) {
			push @set, "ext${bank}_${relay}:on,off,auto" if $caps->{"ext${bank}_${relay}"};
		}

	}

	# Die aktuelle API-Dokumentation unterstützt DIRULE_1..DIRULE_7.
	for my $rule (1..7) {
		push @set, "diRule${rule}:push,lock,unlock" if $caps->{"diRule$rule"};
	}

	# MENU_dosage_N zeigt eine konfigurierte Chemiefunktion unabhängig von ihrem
	# aktuellen Start-/Stoppzustand an.
	my $dosingOk = !$caps->{dosingHardwareChecked} || $caps->{dosingHardware};
	my @chem = (
		[chlor=>'Chlor'], [electrolysis=>'Electrolysis'], [phminus=>'Phminus'],
		[phplus=>'Phplus'], [floc=>'Floc'], [h2o2=>'H2o2']
	);

	# Dosierbefehle nur bei nicht widerlegter oder ausdrücklich bestätigter Hardware anbieten.
	if ($dosingOk) {

		# Für jeden konfigurierten Chemiekanal nur seine technisch möglichen Befehle anbieten.
		for my $entry (@chem) {
			my ($key,$suffix)=@$entry;
			next if !$caps->{"chem_$key"};
			push @set, "dosage${suffix}:start,stop";

			# H2O2 besitzt in der aktuellen API keinen manuellen Ausgang und keinen Kanister.
			if ($key ne 'h2o2') {
				push @set, "dose$suffix";
				my $meta=$VIOLET_CHEM{$key};
				push @set, "canister${suffix}Adjust", "canister${suffix}Reset"
					if defined($meta->{canisterId});
			}
		}

		# Diese Befehle schreiben die in %VIOLET_TARGET zugeordneten Sollwertschlüssel.
		push @set, 'targetPh:slider,6,0.01,8,1' if $caps->{chem_phminus};
		push @set, 'targetOrp:slider,500,1,900',
								'targetMinChlorine:slider,0,0.01,5,1' if $caps->{chem_chlor};

		push @set, 'calibrationRestorePh' if $caps->{chem_phminus} || $caps->{chem_phplus};
		push @set, 'calibrationRestoreOrp'
			if $caps->{chem_chlor} || $caps->{chem_electrolysis} || $caps->{chem_h2o2};
		push @set, 'calibrationRestoreChlor' if $caps->{chlorElectrode};
	}

	my @omni = grep { $caps->{"omni$_"} } 0..5;
	push @set, 'omni:'.join(',',@omni) if $baseOk && @omni;

	return @set;
}

# Vollständige FHEMWEB-Get-Optionen zentral liefern, damit Auswahl und Hilfe bei
# hinzugefügten oder entfernten Get-Befehlen synchron bleiben.
sub VIOLET_GetOptions {
	return (
		'values:noArg',
		'valuesGroup:ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM',
		'outputs:noArg',
		'config:noArg',
		'configKey',
		'services:noArg',
		'localBackups:noArg',
		'updateState:noArg',
		'rs485Data',
		'raw',
	);
}

# Erzeugt die FHEM-Fehlermeldung aus den aktuell sichtbaren Set-Optionen.
sub VIOLET_SetUsage {
	my ($hash) = @_;
	return 'Unknown argument, choose one of '.join(' ', VIOLET_SetOptions($hash));
}

# Erzeugt die FHEM-Fehlermeldung aus der vollständigen Liste der Get-Optionen.
sub VIOLET_GetUsage {
	return 'Unknown argument, choose one of '.join(' ', VIOLET_GetOptions());
}

# Normalisiert optionale Laufzeit- und Pumpenwerte vor einem Funktionsaufruf.
sub VIOLET_SetFunction {
	my ($hash,$key,$action,$duration,$speed) = @_;
	$duration = 0 if !defined $duration || $duration eq '';
	$speed = 0 if !defined $speed || $speed eq '';
	return VIOLET_SetFunctionRaw($hash,$key,$action,$duration,$speed);
}

# Sendet eine bereits validierte Funktionsaktion an setFunctionManually.
sub VIOLET_SetFunctionRaw {
	my ($hash,$key,$action,$v1,$v2) = @_;
	VIOLET_LogCall($hash, 'VIOLET_SetFunctionRaw', $key, $action, $v1, $v2);
	my $payload = join(',', map { defined($_) ? $_ : 0 } ($key,$action,$v1,$v2));
	return VIOLET_Request($hash, method=>'GET', path=>'/setFunctionManually?'.$payload,
		purpose=>'function '.$payload, refresh=>1);
}

# Steuerungskonfiguration für bestimmte geprüfte Set-Befehle schreiben. Die rohe
# /setConfig-API bleibt intern; lesbar ist die Konfiguration über get config.
sub VIOLET_WriteConfig {
	my ($hash,$obj,$purpose) = @_;
	return VIOLET_Request($hash, method=>'POST', path=>'/setConfig',
		data=>VIOLET_FormEncode($obj), contentType=>'application/x-www-form-urlencoded',
		purpose=>$purpose, refresh=>1);
}

# Validiert einen fachlichen Sollwert und schreibt seinen VIOLET-Konfigurationsschlüssel.
sub VIOLET_SetTarget {
	my ($hash, $target, $value) = @_;
	VIOLET_LogCall($hash, 'VIOLET_SetTarget', $target, $value);
	my $key = lc($target // '');

	# Sollwertnamen ablehnen, die keinem schreibbaren VIOLET-Schlüssel ausdrücklich
	# zugeordnet sind; so gelangen keine beliebigen Schlüssel in diesen Kurzbefehl.
	return 'unknown target' if !exists $VIOLET_TARGET{$key};

	# Sollwerte sind numerische Steuerungsparameter. Nichtnumerische Eingaben werden
	# lokal gestoppt, bevor ein HTTP-Aufruf VIOLET erreicht.
	return 'value must be numeric' if !VIOLET_IsNumber($value);

	my $meta = $VIOLET_TARGET{$key};

	# Vor dem Schreiben den dokumentierten Bereich des Sollwerts erzwingen.
	return "value out of range ($meta->{min}..$meta->{max})"
		if $value < $meta->{min} || $value > $meta->{max};

	return VIOLET_WriteConfig(
		$hash,
		{ $meta->{configKey} => 0 + $value },
		"target $key $value"
	);
}

# Validiert eine Kanisterkorrektur und sendet sie an den zugeordneten Dosierkanal.
sub VIOLET_SetCanister {
	my ($hash, $type, $ml, $action) = @_;
	VIOLET_LogCall($hash, 'VIOLET_SetCanister', $type, $ml, $action);

	# Nur Chemiekanäle mit echter VIOLET-Zuordnung von Kanister und Ausgang dürfen
	# /setCanAmount nutzen; h2o2 hat hier z. B. keinen zugeordneten Kanister.
	return 'unknown canister type'
		if !exists($VIOLET_CHEM{$type})
		|| !defined($VIOLET_CHEM{$type}{output})
		|| !defined($VIOLET_CHEM{$type}{canisterId});

	# Kanistermenge als ganzzahlige Milliliter senden; sie muss größer als null sein.
	return 'ml must be a positive integer' if !VIOLET_IsUInt($ml) || $ml < 1;

	# VIOLET akzeptiert für die Kanistermenge nur ADJUST oder RESET.
	return 'action must be adjust or reset' if $action !~ /^(?:adjust|reset)$/i;

	my $chem = $VIOLET_CHEM{$type};
	my $apiAction = uc($action);
	return VIOLET_Request($hash,
		method => 'POST', path => '/setCanAmount',
		data => VIOLET_FormEncode({
			action => $apiAction,
			which  => $chem->{output},
			amount => $ml,
			cid    => $chem->{canisterId},
		}),
		contentType => 'application/x-www-form-urlencoded',
		purpose => "canister $type $ml ".lc($action), refresh => 1);
}

# Startet oder stoppt eine manuelle Dosierung mit einer optionalen Laufzeit.
sub VIOLET_ManualDosing {
	my ($hash,$key,$idx,$action,$seconds) = @_;
	my $form = {
		action            => $action,
		output            => $idx,
		runtime           => $seconds,
		from              => 1,
		runtime_formatted => sprintf('%02d:%02d', int($seconds/60), $seconds%60),
	};
	return VIOLET_Request($hash, method=>'POST', path=>'/triggerManualDosing',
		data=>VIOLET_FormEncode($form), contentType=>'application/x-www-form-urlencoded',
		purpose=>'dosing '.$key.' '.$action.' '.$seconds, refresh=>1);
}


1;
