# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;

# Metadaten und Auflösung der von VIOLET gemeldeten Fehlercodes.
# Die Implementierung bleibt im Paket main, damit FHEM-Callbacks und Kernhelfer
# ohne Adapter- oder Namensänderungen verwendet werden können.

# Metadaten für VIOLET-Meldungen und -Fehler. Manche Firmware-Versionen senden
# ERRORCODE mit führenden Nullen (z. B. 0020); die Suche erfolgt numerisch, während
# die ursprüngliche Schreibweise im FHEM-Reading errorCode erhalten bleibt.
#
# Quelle: aktuelle Fehlercode-Referenz der violet-hass-Community. Die zentrale
# Tabelle vermeidet duplizierte codespezifische Zweige in der Push-Verarbeitung.
my %VIOLET_ERROR_CODES = (
	0   => [ 'MESSAGE',  'info',     'Testnachricht' ],
	1   => [ 'MESSAGE',  'info',     'Statusnachricht' ],
	2   => [ 'ALERT',    'critical', 'Hardwareproblem: COM-Link zum Carrier fehlerhaft' ],
	3   => [ 'REMINDER', 'info',     'Happy Birthday' ],
	8   => [ 'WARNING',  'warning',  'CPU-Temperatur hoch' ],
	9   => [ 'ALERT',    'critical', 'CPU-Temperatur kritisch' ],
	10  => [ 'REMINDER', 'info',     'Update verfügbar - wird automatisch installiert' ],
	11  => [ 'REMINDER', 'info',     'Update verfügbar - Bestätigung erforderlich' ],
	12  => [ 'REMINDER', 'info',     'Update verfügbar - manuell installieren' ],

	20  => [ 'ALERT',    'critical', 'Filterdruck zu niedrig' ],
	21  => [ 'ALERT',    'critical', 'Filterdruck zu hoch' ],
	22  => [ 'WARNING',  'warning',  'Messwasser-Anströmung fehlt' ],
	23  => [ 'WARNING',  'warning',  'Messwasser-Anströmung zu hoch' ],
	24  => [ 'ALERT',    'critical', 'Zirkulation fehlt' ],
	25  => [ 'ALERT',    'critical', 'Zirkulation zu hoch' ],
	26  => [ 'ALERT',    'critical', 'Frostschutz Filterpumpe nicht verfügbar' ],
	27  => [ 'ALERT',    'critical', 'Frostschutz Absorber nicht verfügbar' ],

	30  => [ 'WARNING',  'warning',  'Wärmetauscher-Temperatur hoch' ],
	31  => [ 'ALERT',    'critical', 'Übertemperatur-Schutz nicht verfügbar' ],

	40  => [ 'WARNING',  'warning',  'Rückspülung ausgelassen' ],
	41  => [ 'MESSAGE',  'info',     'Nachspeisung vor Rückspülung fehlgeschlagen' ],
	42  => [ 'MESSAGE',  'info',     'Nachspeisung nicht möglich' ],
	45  => [ 'ALERT',    'critical', 'Omnitronic ohne Rückmeldung (Rückspülen)' ],
	46  => [ 'ALERT',    'critical', 'Omnitronic ohne Rückmeldung (Nachspülen)' ],
	47  => [ 'ALERT',    'critical', 'Omni-Stellantrieb Position nicht erreicht' ],
	49  => [ 'ALERT',    'critical', 'Omnitronic Rückmeldekontakt offen' ],

	50  => [ 'ALERT',    'critical', 'Sicherheitszeit Wassernachspeisung überschritten' ],
	51  => [ 'ALERT',    'critical', 'Oberer Schwimmer hat nicht reagiert' ],
	52  => [ 'ALERT',    'critical', 'Unterer Schwimmer hat nicht zurückgeschaltet' ],

	60  => [ 'ALERT',    'critical', 'Überlaufbehälter: Nachspeisung fehlgeschlagen' ],
	61  => [ 'WARNING',  'warning',  'Überlaufbehälter: Trockenlauf' ],
	62  => [ 'WARNING',  'warning',  'Überlaufbehälter: Pegelmessung fehlerhaft' ],

	71  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 1 ausgelöst' ],
	72  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 2 ausgelöst' ],
	73  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 3 ausgelöst' ],
	74  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 4 ausgelöst' ],
	75  => [ 'MESSAGE',  'info',     'Temperaturregelung Programm 5 ausgelöst' ],
	76  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 6 ausgelöst' ],
	77  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 7 ausgelöst' ],
	78  => [ 'WARNING',  'warning',  'Temperaturregelung Programm 8 ausgelöst' ],

	120 => [ 'WARNING',  'warning',  'Redox-Grenzwert Chlor-Dosierung' ],
	121 => [ 'WARNING',  'warning',  'Chlor-Grenzwert Dosierung' ],
	122 => [ 'WARNING',  'warning',  'Max. Tagesdosierung Chlor überschritten' ],
	123 => [ 'WARNING',  'warning',  'Chlor-Kanister niedrig' ],
	124 => [ 'WARNING',  'warning',  'Chlor-Kanister leer' ],
	125 => [ 'WARNING',  'warning',  'Leermelder-Kontakt Chlor-Sauglanze' ],

	130 => [ 'WARNING',  'warning',  'Redox-Grenzwert Elektrolyse' ],
	131 => [ 'WARNING',  'warning',  'Chlor-Grenzwert Elektrolyse' ],
	132 => [ 'WARNING',  'warning',  'Max. Tagesproduktion Elektrolyse' ],
	133 => [ 'WARNING',  'warning',  'Elektrolyse Restlaufzeit' ],
	134 => [ 'WARNING',  'warning',  'Max. Betriebszeit Elektrolyse-Zelle' ],
	135 => [ 'WARNING',  'warning',  'Durchflussschalter Elektrolyse' ],

	142 => [ 'WARNING',  'warning',  'H2O2 max. Tagesdosierung' ],
	143 => [ 'WARNING',  'warning',  'H2O2-Kanister niedrig' ],
	144 => [ 'WARNING',  'warning',  'H2O2-Kanister leer' ],
	145 => [ 'WARNING',  'warning',  'Leermelder Sauerstoff-Kanister' ],

	150 => [ 'WARNING',  'warning',  'pH-minus Grenzwert' ],
	152 => [ 'WARNING',  'warning',  'pH-minus max. Tagesdosierung' ],
	153 => [ 'WARNING',  'warning',  'pH-minus Kanister niedrig' ],
	154 => [ 'WARNING',  'warning',  'pH-minus Kanister leer' ],
	155 => [ 'WARNING',  'warning',  'pH-minus Leermelder' ],
	160 => [ 'WARNING',  'warning',  'pH-plus Grenzwert' ],
	162 => [ 'WARNING',  'warning',  'pH-plus max. Tagesdosierung' ],
	163 => [ 'WARNING',  'warning',  'pH-plus Kanister niedrig' ],
	164 => [ 'WARNING',  'warning',  'pH-plus Kanister leer' ],
	165 => [ 'WARNING',  'warning',  'pH-plus Leermelder' ],

	172 => [ 'WARNING',  'warning',  'Flockmittel max. Tagesdosierung' ],
	173 => [ 'WARNING',  'warning',  'Flockmittel-Kanister niedrig' ],
	174 => [ 'WARNING',  'warning',  'Flockmittel-Kanister leer' ],
	175 => [ 'WARNING',  'warning',  'Flockmittel Leermelder' ],

	180 => [ 'REMINDER', 'info',     'pH-Elektrode kalibrieren fällig' ],
	181 => [ 'REMINDER', 'info',     'Redox-Elektrode kalibrieren fällig' ],
	182 => [ 'REMINDER', 'info',     'Chlor-Elektrode kalibrieren fällig' ],

	200 => [ 'WARNING',  'warning',  'Dosiermodul getrennt' ],
	201 => [ 'WARNING',  'warning',  'Dosiermodul Kommunikation verloren' ],
	203 => [ 'WARNING',  'warning',  'Relais-Erweiterung 1 getrennt' ],
	204 => [ 'WARNING',  'warning',  'Relais-Erweiterung 1 Kommunikation verloren' ],
	206 => [ 'WARNING',  'warning',  'Relais-Erweiterung 2 getrennt' ],
	207 => [ 'WARNING',  'warning',  'Relais-Erweiterung 2 Kommunikation verloren' ],
	209 => [ 'ALERT',    'critical', 'Zweites Dosiermodul erkannt' ],
	210 => [ 'ALERT',    'critical', 'Falsch codierte Relais-Erweiterung' ],
);

# Einen numerischen VIOLET-Fehlercode auflösen. Als Familie dokumentierte Bereiche
# werden hier erzeugt, statt sie als wiederholte Tabelleneinträge auszuschreiben.
sub VIOLET_ErrorMetadata {
	my ($rawCode) = @_;
	return ('UNKNOWN', 'unknown', 'Unbekannter Fehlercode')
		if !defined($rawCode) || $rawCode !~ /^\d+$/;

	my $code = 0 + $rawCode;

	# Exakt dokumentierte Einzelcodes direkt aus der zentralen Tabelle liefern.
	if (my $entry = $VIOLET_ERROR_CODES{$code}) {
		return @$entry;
	}

	# Die Dokumentation der Analog-/Schaltregeln nennt Bereiche ohne Schweregrad je
	# Code. Ausgelöste Regeln gelten für FHEM-Meldungen als Warnungen; ihre genaue
	# Regelnummer bleibt in errorText erhalten.
	if ($code >= 81 && $code <= 88) {
		return ('WARNING', 'warning',
			'Analogregel-Programm '.($code - 80).' ausgelöst');
	}

	# Schaltregelcodes 91 bis 98 tragen ihre Programmnummer im Zahlenbereich.
	if ($code >= 91 && $code <= 98) {
		return ('WARNING', 'warning',
			'Schaltregel-Programm '.($code - 90).' ausgelöst');
	}

	# Temperatursensorfehler 101..112 sind als WARNING dokumentiert; die Nummer des
	# physischen Sensors wird direkt aus dem Code abgeleitet.
	if ($code >= 101 && $code <= 112) {
		return ('WARNING', 'warning',
			'Temperatursensor '.($code - 100).' fehlt');
	}

	return ('UNKNOWN', 'unknown', 'Unbekannter Fehlercode');
}


1;
