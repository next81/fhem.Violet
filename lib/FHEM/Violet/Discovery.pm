# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;
use vars qw(%VIOLET_CHEM %VIOLET_TARGET);

# Erkennung der konfigurierten Funktionen und tatsächlich vorhandenen Hardware.
# Die Implementierung bleibt im Paket main, damit FHEM-Callbacks und Kernhelfer
# ohne Adapter- oder Namensänderungen verwendet werden können.

# Leitet die in FHEMWEB sichtbaren Set-Fähigkeiten aus der flachen Konfiguration ab.
sub VIOLET_BuildSetCapabilities {
	my ($hash,$flat)=@_;
	return {} if ref($flat) ne 'HASH';
	my %caps=(discovered=>1);

	my %control=(
		pump=>'MENU_control_1', solar=>'MENU_control_2', heater=>'MENU_control_3',
		backwash=>'MENU_control_4', refill=>'MENU_control_5', light=>'MENU_control_7',
		cover=>'MENU_control_8'
	);

	# Jeden Menüschalter auf die zugehörige öffentliche Steuerungsfunktion abbilden.
	for my $feature (keys %control) {
		$caps{$feature}=VIOLET_ConfigValueEnabled(VIOLET_ConfigFlatValue($flat,$control{$feature}))?1:0;
	}

	my $pumpType=VIOLET_ConfigFlatValue($flat,'PUMP_type');
	$caps{pumpType}="$pumpType" if defined($pumpType) && "$pumpType" =~ /^[012]$/;
	$caps{lightColor}=VIOLET_ConfigValueEnabled(VIOLET_ConfigFlatValue($flat,'LIGHT_control_has_colorchange'))?1:0;
	$caps{dmx}=($caps{light} && VIOLET_ConfigValueEnabled(VIOLET_ConfigFlatValue($flat,'LIGHT_control_dmx')))?1:0;
	my $dmxCount=VIOLET_ConfigFlatValue($flat,'LIGHT_control_max_dmx_pattern');

	# Die Szenenanzahl nur bei aktivem DMX und gültiger numerischer Konfiguration übernehmen.
	if ($caps{dmx} && defined($dmxCount) && "$dmxCount" =~ /^\d+$/) {
		$dmxCount=12 if $dmxCount>12;
		$caps{dmxCount}=$dmxCount>0 ? 0+$dmxCount : 0;
	} else { $caps{dmxCount}=0; }

	my %dosage=(
		chlor=>'MENU_dosage_1', electrolysis=>'MENU_dosage_2', h2o2=>'MENU_dosage_3',
		phminus=>'MENU_dosage_4', phplus=>'MENU_dosage_5', floc=>'MENU_dosage_6'
	);

	# Jeden Dosier-Menüschalter auf den kanonischen Chemienamen abbilden.
	for my $type (keys %dosage) {
		$caps{"chem_$type"}=VIOLET_ConfigValueEnabled(VIOLET_ConfigFlatValue($flat,$dosage{$type}))?1:0;
	}

	$caps{chlorElectrode}=VIOLET_ConfigValueEnabled(VIOLET_ConfigFlatValue($flat,'DOSAGE_cl_electrode_use'))?1:0;

	# Einzelne Erweiterungsrelais und Omni-Positionen werden über ihre Namen konfiguriert.
	for my $bank (1,2) {

		# Alle acht möglichen Relais einer Erweiterungsbank auf konfigurierte Namen prüfen.
		for my $relay (1..8) {
			my $name=VIOLET_ConfigFlatValue($flat,"NAMES_EXT${bank}_${relay}");
			$caps{"ext${bank}_${relay}"}=VIOLET_ConfigValueEnabled($name)?1:0;
		}

	}

	# Alle sechs möglichen Omni-Positionen auf einen konfigurierten Namen prüfen.
	for my $pos (0..5) {
		my $name=VIOLET_ConfigFlatValue($flat,"NAMES_omni_dz$pos");
		$caps{"omni$pos"}=VIOLET_ConfigValueEnabled($name)?1:0;
	}

	# Firmwareabhängige Regelkonfigurationsnamen nur akzeptieren, wenn ein
	# ausdrückliches Regelfeld einen sinnvollen Wert enthält.
	for my $key (keys %$flat) {
		my $safe=uc(VIOLET_SanitizeReading($key));
		next if !VIOLET_ConfigValueEnabled($flat->{$key});
		$caps{"diRule$1"}=1
			if $safe =~ /(?:DIGITALINPUTRULE|DIGITAL_INPUT_RULE|DIRULE).*?(?:RULE_?)?([1-7])(?:_|$)/;
		$caps{eco}=1 if $safe =~ /^ECO(?:_|$)/ && $safe =~ /(?:USE|ENABLED|ACTIVE)$/;
		$caps{pvSurplus}=1 if $safe =~ /^PVSURPLUS(?:_|$)/ && $safe =~ /(?:USE|ENABLED|ACTIVE)$/;
	}

	# Erkannte Hardware-Anwesenheit aus dem vorherigen Reading-Zyklus behalten.
	my $old=(ref($hash->{helper}) eq 'HASH' && ref($hash->{helper}{setCapabilities}) eq 'HASH')
		? $hash->{helper}{setCapabilities} : {};

	# Zustand von Basis-/Dosierhardware darf beim Neuaufbau erhalten bleiben. EXT-
	# Hardware bewusst nicht: Jede neue Erkennung verbirgt EXT-Befehle, bis das
	# folgende getReadings EXT1_1 oder EXT2_1 erneut bestätigt. So gelangen
	# standardmäßige NAMES_EXT*-Einträge nicht in Set.
	for my $key (qw(baseHardwareChecked baseHardware dosingHardwareChecked dosingHardware)) {
		$caps{$key}=$old->{$key} if exists $old->{$key};
	}

	return \%caps;
}

# Konfigurierte Fähigkeiten anhand tatsächlich vorhandener Hardware verfeinern.
sub VIOLET_UpdateHardwareCapabilities {
	my ($hash,$flat)=@_;
	return if ref($hash) ne 'HASH' || ref($flat) ne 'HASH';
	return if ref($hash->{helper}) ne 'HASH' || ref($hash->{helper}{setCapabilities}) ne 'HASH';
	my $caps=$hash->{helper}{setCapabilities};
	return if !$caps->{discovered};

	my ($base,$dosing,$ext1,$ext2)=(0,0,0,0);

	# Nur belastbare Kern- und Modulmerkmale aus der Reading-Antwort auswerten.
	for my $key (keys %$flat) {
		my $safe=uc(VIOLET_SanitizeReading($key));
		$base=1 if $safe eq 'PUMP' || $safe =~ /^PUMP_/;

		# Manche VIOLET-Firmware liefert DOS_*- und EXT*-Platzhalter ohne zugehörige
		# Hardware. Nur Modul-Lebenszähler als Anwesenheitsnachweis verwenden.
		$dosing=1 if $safe eq 'SYSTEM_DOSAGEMODULE_ALIVE_COUNT';
		$ext1=1   if $safe eq 'SYSTEM_EXT1MODULE_ALIVE_COUNT';
		$ext2=1   if $safe eq 'SYSTEM_EXT2MODULE_ALIVE_COUNT';
		$caps->{"diRule$1"}=1
			if $safe =~ /(?:DIGITALINPUTRULE|DIGITAL_INPUT_RULE).*?(?:RULE_?)?([1-7])(?:_|$)/;
	}

	$caps->{baseHardwareChecked}=1; $caps->{baseHardware}=$base?1:0;
	$caps->{dosingHardwareChecked}=1; $caps->{dosingHardware}=$dosing?1:0;

	# Für jede Erweiterungsbank nur bei mindestens einem konfigurierten Relais prüfen.
	for my $bank (1,2) {
		my $configured=0;

		# Ein einzelnes konfiguriertes Relais macht den Hardwarestatus der Bank relevant.
		for my $relay (1..8) {
			$configured = 1 if $caps->{"ext${bank}_${relay}"};
		}

		next if !$configured;
		my $present=$bank==1?$ext1:$ext2;
		$caps->{"ext${bank}HardwareChecked"}=1;
		$caps->{"ext${bank}Hardware"}=$present?1:0;
	}

}

# Ein API-Präfix zur Steuerungsabfrage und lokalen Positivliste ergänzen. Die
# lokale Liste ist nötig, weil RUNTIMES und DOSAGE mehr Kanäle liefern, als die
# Steuerung einzeln filtern kann. Erweiterungskanäle erst aufnehmen, nachdem ein
# ungefiltertes Hardwareprofil SYSTEM_ext*module_alive_count bestätigt hat.
# Rohe EXT_*-Werte gelten nie als Hardwarenachweis.
sub VIOLET_AddConfirmedExtensionPrefixes {
	my ($hash) = @_;
	return if ref($hash) ne 'HASH';
	return if ref($hash->{helper}) ne 'HASH' || ref($hash->{helper}{setCapabilities}) ne 'HASH';

	my $caps = $hash->{helper}{setCapabilities};
	my %tokens = map { $_ => 1 }
		grep { defined($_) && $_ ne '' }
		split(/\s*,\s*/, $hash->{VIOLET_AUTO_QUERY} // '');
	my $allowed = ref($hash->{VIOLET_ACTIVE_PREFIXES}) eq 'HASH'
		? $hash->{VIOLET_ACTIVE_PREFIXES}
		: {};

	# Nur hardwareseitig bestätigte Erweiterungsbanken in die optimierte Abfrage aufnehmen.
	for my $bank (1,2) {
		next if !$caps->{"ext${bank}HardwareChecked"};
		next if !$caps->{"ext${bank}Hardware"};

		# Innerhalb der Bank ausschließlich konfigurierte Relaispräfixe ergänzen.
		for my $relay (1..8) {
			next if !$caps->{"ext${bank}_${relay}"};
			VIOLET_AddActivePrefix(\%tokens, $allowed, "EXT${bank}_${relay}");
		}

	}

	$hash->{VIOLET_AUTO_QUERY} = join(', ', sort keys %tokens);
	$hash->{VIOLET_ACTIVE_PREFIXES} = $allowed;
}

# Eine ungefilterte Antwort von /getReadings?ALL nur auf Hardwareanwesenheit
# auswerten. Kein Wert dieser Prüfung wird als FHEM-Reading veröffentlicht;
# Erweiterungen erkennt ausschließlich SYSTEM_ext*module_alive_count.
sub VIOLET_ApplyHardwareDiscovery {
	my ($hash, $body) = @_;
	VIOLET_LogCall($hash, 'VIOLET_ApplyHardwareDiscovery', 'bodyLength='.length($body // ''));

	my ($obj, $jsonErr) = VIOLET_DecodeJsonResponse($body);

	# Fehlerhafte oder unstrukturierte Antworten dürfen den Hardwarestatus nicht verändern.
	if (defined($jsonErr) || !ref($obj)) {
		VIOLET_Log($hash, 2, 'hardware discovery JSON parse error: '.
			VIOLET_LogValue($jsonErr // 'response is not structured JSON'));
		return 0;
	}

	# Dieselbe optionale Hülle wie bei der normalen Reading-Auswertung normalisieren.
	if (ref($obj) eq 'HASH' && ref($obj->{getReadings})) {
		$obj = $obj->{getReadings};
	}

	my %flat;
	VIOLET_Flatten('', $obj, \%flat);
	VIOLET_UpdateHardwareCapabilities($hash, \%flat);
	VIOLET_AddConfirmedExtensionPrefixes($hash);
	return 1;
}

# Ergänzt Abfragetoken und lokale Positivliste um dasselbe normalisierte API-Präfix.
sub VIOLET_AddActivePrefix {
	my ($tokens, $allowed, $prefix) = @_;
	return if !defined($prefix) || $prefix eq '';
	$tokens->{$prefix} = 1;
	$allowed->{uc(VIOLET_SanitizeReading($prefix))} = 1;
}

# Nur die wenigen betrieblichen Sollwerte aus /getConfig veröffentlichen. Rohe
# Konfigurationsschlüssel werden bewusst nie config*-Readings. Kanonische Namen
# stammen aus %VIOLET_TARGET, damit Set-Prüfung und Veröffentlichung stets
# dieselben Steuerungsschlüssel verwenden.
sub VIOLET_PublishConfigTargets {
	my ($hash, $flat) = @_;
	return 0 if ref($flat) ne 'HASH';

	my $count = 0;

	# Jeden bekannten Sollwert anhand seines exakten Konfigurationsschlüssels suchen.
	for my $target (sort keys %VIOLET_TARGET) {
		my $meta = $VIOLET_TARGET{$target};
		my $wanted = uc(VIOLET_SanitizeReading($meta->{configKey}));

		# Firmwareabhängige Schreibweisen normalisieren und den ersten Treffer übernehmen.
		for my $key (keys %$flat) {
			next if uc(VIOLET_SanitizeReading($key)) ne $wanted;
			my $reading = VIOLET_CamelCaseReading($meta->{configKey});

			# Null ist für manche Kanäle ein gültiger Sollwert, besonders chlorMinTarget;
			# deshalb umgehen Sollwert-Readings die anfängliche Leer-/Nullunterdrückung.
			VIOLET_BulkUpdateReading($hash, $reading, $flat->{$key}, 0, 0);
			$count++;
			last;
		}

	}

	return $count;
}

# Optimierte /getReadings-Abfrage aus der vollständigen VIOLET-Konfiguration
# bilden. Nur stabile System-/Kernwerte und ausdrücklich aktivierte oder benannte
# Funktionen verbleiben in der aktiven Positivliste.
sub VIOLET_ApplyConfigDiscovery {
	my ($hash, $body) = @_;
	VIOLET_LogCall($hash, 'VIOLET_ApplyConfigDiscovery', 'bodyLength='.length($body // ''));
	my ($obj, $jsonErr) = VIOLET_DecodeJsonResponse($body);

	# Fehlerhaftes JSON verhindert die Konfigurationserkennung.
	if (defined($jsonErr) || !ref($obj)) {
		VIOLET_Log($hash, 1, 'critical config JSON parse error: '.
			VIOLET_LogValue($jsonErr // 'response is not structured JSON'));
		return 0;
	}

	# Manche Firmware-/API-Hüllen legen die eigentliche Konfiguration unter getConfig ab.
	if (ref($obj) eq 'HASH' && ref($obj->{getConfig}) eq 'HASH') {
		$obj = $obj->{getConfig};
	}

	my %flat;
	VIOLET_Flatten('', $obj, \%flat);

	# Dynamische FHEMWEB-Set-Liste aus derselben authentifizierten Konfiguration bilden.
	$hash->{helper} = {} if ref($hash->{helper}) ne 'HASH';
	$hash->{helper}{setCapabilities} = VIOLET_BuildSetCapabilities($hash, \%flat);

	my %tokens;
	my %allowed;

	# Systemzustand und Filterpumpe gelten als Kernwerte der Steuerung.
	for my $prefix (qw(SYSTEM fw SW_VERSION HW_VERSION HW_SERIAL CPU LOAD_AVG MEMORY PUMP)) {
		VIOLET_AddActivePrefix(\%tokens, \%allowed, $prefix);
	}

	# Dies sind Funktionsmerkmale der Steuerung, keine einfachen Regex-Präfixe.
	# Zusätzlich gelieferte fremde Werte entfernt der lokale Aktivfilter wieder.
	$tokens{PUMPPRIOSTATE} = 1;
	$tokens{RUNTIMES} = 1;
	$allowed{PUMPSTATE} = 1;
	$allowed{PUMPPRIOSTATE} = 1;

	my %chemActive;
	my %featureActive;
	my %onewireActive;

	# Ausdrückliche Schalter *_use, *_enabled und *_active prüfen. Gespeicherte
	# Sollwerte allein gelten bewusst nicht als Nachweis einer aktiven Funktion.
	for my $key (keys %flat) {
		my $value = $flat{$key};
		my $safe = VIOLET_SanitizeReading($key);

		# Aktivierte Dosierpräfixe zuerst auf die zentrale Chemietabelle zurückführen.
		if ($safe =~ /^(DOSAGE_[A-Z0-9_]+)_(?:USE|ENABLED|ACTIVE)$/i && VIOLET_ConfigValueEnabled($value)) {
			my $prefix = uc($1);

			# VIOLET-Konfigurationspräfixe DOSAGE_* auf kanonische Chemienamen zurückführen.
			for my $type (keys %VIOLET_CHEM) {
				my $cfg = $VIOLET_CHEM{$type}{configPrefix};
				next if !defined($cfg);

				# Das erste exakt passende Konfigurationspräfix aktiviert den Chemiekanal.
				if (uc(VIOLET_SanitizeReading($cfg)) eq $prefix) {
					$chemActive{$type} = 1;
					last;
				}
			}

			next;
		}

		# Alle übrigen expliziten Aktivschalter als generische Funktionsmerkmale merken.
		if ($safe =~ /^([A-Z0-9]+(?:_[A-Z0-9]+)*)_(?:USE|ENABLED|ACTIVE)$/i && VIOLET_ConfigValueEnabled($value)) {
			$featureActive{uc($1)} = 1;
		}

		# Ein sinnvolles OneWire-Feld wie Name, ROM-Code oder Adresse kennzeichnet den
		# nummerierten Steckplatz als bewusst konfiguriert.
		if ($safe =~ /(?:^|_)ONEWIRE(\d+)(?:_|$)/i && VIOLET_ConfigValueEnabled($value)) {
			$onewireActive{$1} = 1;
		}
	}

	# MENU_dosage_N erkennt konfigurierte Kanäle unabhängig von Start/Stopp.
	my $cfgCaps = $hash->{helper}{setCapabilities};

	# Nur eine tatsächlich erzeugte Capability-Struktur in die Chemieauswahl einbeziehen.
	if (ref($cfgCaps) eq 'HASH') {

		# Alle bekannten Chemiekanäle aus der Set-Discovery in die aktive Liste übernehmen.
		for my $type (qw(chlor electrolysis phminus phplus floc h2o2)) {
			$chemActive{$type}=1 if $cfgCaps->{"chem_$type"};
		}

	}

	# DOSAGE ist in VIOLET ein Funktionsmerkmal für alle Kanäle.
	if (%chemActive) {
		$tokens{DOSAGE} = 1;

		# Abfrage- und Filterpräfixe für jeden aktiven Chemiekanal gemeinsam ergänzen.
		for my $type (keys %chemActive) {
			my $output = $VIOLET_CHEM{$type}{output};
			VIOLET_AddActivePrefix(\%tokens, \%allowed, $output) if defined($output);

			# DOSAGE fordert bereits DOSAGE_*-Werte an. Nur Konfigurationspräfixe aktiver
			# Chemiekanäle erlauben, damit Sollwerte/Einstellungen inaktiver Kanäle keine
			# Readings werden.
			my $configPrefix = $VIOLET_CHEM{$type}{configPrefix};
			$allowed{uc(VIOLET_SanitizeReading($configPrefix))} = 1 if defined($configPrefix);

			# Nur Sensorfamilien ergänzen, die für aktive Chemiefunktionen wichtig sind.
			VIOLET_AddActivePrefix(\%tokens, \%allowed, 'pH')  if $type eq 'phminus' || $type eq 'phplus';
			VIOLET_AddActivePrefix(\%tokens, \%allowed, 'orp') if $type eq 'chlor' || $type eq 'electrolysis' || $type eq 'h2o2';
			VIOLET_AddActivePrefix(\%tokens, \%allowed, 'pot') if $type eq 'chlor' || $type eq 'electrolysis';
		}

		# Elektrolyse-Polarität und Umkehrzustand verwenden eigene interne Präfixe.
		if ($chemActive{electrolysis}) {
			VIOLET_AddActivePrefix(\%tokens, \%allowed, 'DOS_2_CURRENT');
			VIOLET_AddActivePrefix(\%tokens, \%allowed, 'DOS_3_ELO_REV');
		}
	}

	# MENU_control_N ist das maßgebliche Konfigurationsmerkmal der WebUI.
	my $setCaps = $hash->{helper}{setCapabilities};

	# Nur eine gültige Capability-Struktur auf generische Funktionsmerkmale übertragen.
	if (ref($setCaps) eq 'HASH') {
		$featureActive{PUMP}=1 if $setCaps->{pump};
		$featureActive{SOLAR}=1 if $setCaps->{solar};
		$featureActive{HEATER}=1 if $setCaps->{heater};
		$featureActive{BACKWASH}=1 if $setCaps->{backwash};
		$featureActive{REFILL}=1 if $setCaps->{refill};
		$featureActive{LIGHT}=1 if $setCaps->{light};
		$featureActive{COVER}=1 if $setCaps->{cover};
	}

	# Übliche aktive Nicht-Chemiefunktionen ihren Reading-Präfixen zuordnen. Der
	# Präfixvergleich erfasst auch Firmwarevarianten wie LEVEL_* für Nachspeisung.
	my %featureMap = (
		PUMP      => [qw(PUMP)],
		SOLAR     => [qw(SOLAR)],
		HEATER    => [qw(HEATER)],
		LIGHT     => [qw(LIGHT DMX_SCENE)],
		ECO       => [qw(ECO)],
		BACKWASH  => [qw(BACKWASH BACKWASHRINSE)],
		REFILL    => [qw(REFILL LEVEL OVERFLOW)],
		LEVEL     => [qw(REFILL LEVEL OVERFLOW)],
		OVERFLOW  => [qw(OVERFLOW REFILL LEVEL)],
		COVER     => [qw(COVER)],
		PVSURPLUS => [qw(PVSURPLUS)],
	);

	# Jedes erkannte Funktionsmerkmal gegen die bekannten API-Familien abgleichen.
	for my $feature (keys %featureActive) {

		# Die längeren Firmwaremerkmale ihrem kanonischen Basistoken zuordnen.
		for my $base (keys %featureMap) {
			next if $feature !~ /^\Q$base\E(?:_|$)/;

			# Alle zur Basisfunktion gehörenden Reading-Präfixe freigeben.
			for my $prefix (@{$featureMap{$base}}) {
				VIOLET_AddActivePrefix(\%tokens, \%allowed, $prefix);
			}

			$tokens{BACKWASH} = 1 if $base eq 'BACKWASH';
		}

	}

	# DMX wird über LIGHT_control_dmx und die maximale Musteranzahl konfiguriert.
	my $capSnapshot=$hash->{helper}{setCapabilities};

	# Szenen nur bei ausdrücklich aktivierter DMX-Funktion ergänzen.
	if (ref($capSnapshot) eq 'HASH' && $capSnapshot->{dmx}) {

		# Nur die von der Steuerung gemeldete Zahl an DMX-Szenen abfragen.
		for my $scene (1..($capSnapshot->{dmxCount} || 0)) {
			VIOLET_AddActivePrefix(\%tokens, \%allowed, 'DMX_SCENE'.$scene);
		}

	}

	# Erweiterungsnamen allein sind kein Hardwarenachweis. Firmware kann NAMES_EXT*
	# und rohe EXT*-Platzhalter ohne Platine liefern. EXT-Präfixe erst ergänzen,
	# wenn SYSTEM_ext*module_alive_count das Modul bestätigt. DMX bleibt wegen des
	# ausdrücklichen LIGHT_control_dmx konfigurationsgesteuert.
	for my $key (keys %flat) {
		next if !VIOLET_ConfigValueEnabled($flat{$key});
		my $safe = uc(VIOLET_SanitizeReading($key));

		# Benannte DMX-Szenen auch ohne fortlaufende Szenenzahl freigeben.
		if ($safe =~ /^NAMES_(DMX_SCENE\d+)$/) {
			VIOLET_AddActivePrefix(\%tokens, \%allowed, $1);
		}
	}

	# Nur konfigurierte OneWire-Steckplätze abfragen und ihre Anzeigenamen aus
	# derselben Konfiguration veröffentlichen; kein eigener Metadatenaufruf nötig.
	for my $slot (sort { $a <=> $b } keys %onewireActive) {
		VIOLET_AddActivePrefix(\%tokens, \%allowed, 'onewire'.$slot);
	}

	readingsBeginUpdate($hash);

	# Für jeden aktiven OneWire-Steckplatz den konfigurierten Anzeigenamen suchen.
	for my $slot (sort { $a <=> $b } keys %onewireActive) {
		my $wanted = uc(VIOLET_SanitizeReading('NAMES_onewire'.$slot));

		# Den normalisierten Namensschlüssel unabhängig von der Firmware-Schreibweise finden.
		for my $key (keys %flat) {
			next if uc(VIOLET_SanitizeReading($key)) ne $wanted;
			VIOLET_BulkUpdateReading($hash, 'onewire'.$slot.'Name', $flat{$key}, 0, 1);
			last;
		}

	}

	# Nur fachliche Betriebssollwerte aus der Konfiguration behalten. Den Rest nur
	# intern zur Erkennung nutzen und nie als Readings veröffentlichen.
	VIOLET_PublishConfigTargets($hash, \%flat);
	readingsEndUpdate($hash, 1);

	# Erzeugte Abfrage einmal mit Leerzeichen nach Kommas speichern, damit FHEMWEB
	# das lange Internal umbrechen kann. Vor dem Senden entfernt
	# VIOLET_EffectiveReadingsQuery die Leerzeichen zentral.
	my @queryTokens = sort keys %tokens;
	$hash->{VIOLET_AUTO_QUERY} = join(', ', @queryTokens);
	$hash->{VIOLET_ACTIVE_PREFIXES} = \%allowed;
	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = time();
	return 1;
}

# Wahr liefern, wenn ein roher /getReadings-Schlüssel zu einer konfigurierten
# Funktion gehört. Pauschalmerkmale wie DOSAGE und RUNTIMES können trotz
# optimierter Grundabfrage inaktive Kanäle ergänzen.
sub VIOLET_IsActiveApiKey {
	my ($hash, $key) = @_;
	my $allowed = $hash->{VIOLET_ACTIVE_PREFIXES};
	return 1 if ref($allowed) ne 'HASH' || !%$allowed;
	my $safe = uc(VIOLET_SanitizeReading($key));

	# Die Markierung dient interner Buchführung und ist kein Benutzerwert.
	return 0 if $safe eq 'CONFIGCHANGEMARKER';

	# Den Schlüssel gegen jedes während der Discovery freigegebene Präfix prüfen.
	for my $prefix (keys %$allowed) {
		return 1 if $safe =~ /^\Q$prefix\E(?:_|$)/;
	}

	return 0;
}

# Optionale manuelle oder aus der Konfiguration abgeleitete Abfrage lesen und
# Darstellungsleerzeichen vor dem Anhängen an /getReadings entfernen. So bleibt
# nur ein sichtbares VIOLET_AUTO_QUERY-Internal ohne Änderung der API.
sub VIOLET_EffectiveReadingsQuery {
	my ($hash) = @_;
	my $query = AttrVal($hash->{NAME}, 'readingsQuery', '');

	# Ohne manuelle Vorgabe auf die zuletzt automatisch ermittelte Abfrage zurückfallen.
	if ((!defined($query) || $query eq '') && defined($hash->{VIOLET_AUTO_QUERY})) {
		$query = $hash->{VIOLET_AUTO_QUERY};
	}
	return undef if !defined($query) || $query eq '';

	# Leerzeichen dienen nur dem FHEMWEB-Umbruch und gehören nicht zu VIOLET-
	# Abfragetoken; deshalb vor dem Senden alle Leerzeichen entfernen.
	$query =~ s/\s+//g;
	return $query;
}

# Konfiguration anfangs und alle 15 Minuten erkennen. Ein manuelles readingsQuery
# überschreibt die Funktionsauswahl erst nach bestätigter Authentifizierung.
sub VIOLET_RequestAutoValues {
	my ($hash, $purpose) = @_;
	VIOLET_LogCall($hash, 'VIOLET_RequestAutoValues', $purpose);

	# VIOLET erst mit vollständigem Benutzernamen und Passwort kontaktieren. Eine
	# abgelehnte Anmeldung bleibt bis zur Änderung einer Zugangskomponente gesperrt.
	if (!VIOLET_CredentialsReady($hash)) {
		VIOLET_UpdateCredentialState($hash);
		return 'credentials are required before polling';
	}

	# Vor bestätigter Authentifizierung immer das geschützte /getConfig verwenden.
	# Erst danach dürfen manuelle oder zwischengespeicherte Abfragen direkt starten.
	if ($hash->{VIOLET_AUTH_VALIDATED}) {
		my $manual = AttrVal($hash->{NAME}, 'readingsQuery', '');

		# Ein manuelles readingsQuery wirkt ausdrücklich überschreibend. Dieselbe
		# Normalisierung wie bei erzeugten Abfragen verwenden.
		if (defined($manual) && $manual ne '') {
			my $query = VIOLET_EffectiveReadingsQuery($hash);
			return VIOLET_Request($hash, method=>'GET', path=>'/getReadings?'.$query,
				purpose=>$purpose, parseReadings=>1, activeFilter=>0, refresh=>0);
		}

		my $age = time() - ($hash->{VIOLET_CONFIG_DISCOVERED_AT} || 0);
		my $query = VIOLET_EffectiveReadingsQuery($hash);

		# Ein frisches Erkennungsergebnis ohne weiteren /getConfig-Aufruf wiederverwenden.
		if (defined($query) && $age < 900) {
			return VIOLET_Request($hash, method=>'GET', path=>'/getReadings?'.$query,
				purpose=>$purpose, parseReadings=>1, activeFilter=>1, refresh=>0);
		}
	}

	# Überlappende Timer-/Manuellaufrufe während laufender Erkennung zusammenfassen.
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = $purpose;
	return undef if $hash->{VIOLET_CONFIG_DISCOVERY_PENDING} || $hash->{VIOLET_HARDWARE_DISCOVERY_PENDING};
	$hash->{VIOLET_CONFIG_DISCOVERY_PENDING} = 1;
	return VIOLET_Request($hash, method=>'GET', path=>'/getConfig',
		purpose=>'discoverConfig', refresh=>0);
}


1;
