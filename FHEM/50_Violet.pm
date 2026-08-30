###############################################################################
# 50_Violet.pm
# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773
#
# FHEM-Modul für die PoolDigital-VIOLET-Poolsteuerung
#
# Umfang:
#   - Benutzername und Passwort vor jedem API-Aufruf und Polling verlangen
#   - Konfigurierte VIOLET-Funktionen erkennen und nur relevante /getReadings-Schlüssel abfragen
#   - HTTP-Push-Parameter der Steuerung über /fhem/VIOLET?device=<name>&... empfangen
#   - Benutzerfreundliche Set-Befehle für alle dokumentierten VIOLET-Schreib-APIs
#   - Generische Raw-Rückfallwege für Firmware-Erweiterungen
#
# API-Grundlage: VIOLET-Software 1.1.9 / API-Referenz 05/2026 und aktueller
# Stand des Projekts violet-poolController-api (geprüft am 2026-08-09).
###############################################################################

package main;

use strict;
use warnings;
use lib './lib';
use FHEM::Violet::Module ();

# Delegiert das Verwerfen von Authentifizierungs- und Discovery-Zustand an die Bibliothek.
sub VIOLET_InvalidateSession {
	my ($hash) = @_;
	return FHEM::Violet::Module::invalidate_session($hash);
}

# Registriert das FHEM-Modul über die ausgelagerte Implementierung.
sub VIOLET_Initialize($) {
	my ($hash) = @_;
	return FHEM::Violet::Module::initialize($hash, $main::readingFnAttributes);
}

# Delegiert das nebenwirkungsfreie Lesen der Zugangsdaten an die Bibliothek.
sub VIOLET_CredentialsInfo {
	return FHEM::Violet::Module::credentials_info(@_);
}

# Delegiert die Prüfung vollständiger und nicht abgelehnter Zugangsdaten.
sub VIOLET_CredentialsReady {
	return FHEM::Violet::Module::credentials_ready(@_);
}

# Delegiert die sichtbare Aktualisierung des Zugangsdatenzustands an die Bibliothek.
sub VIOLET_UpdateCredentialState {
	return FHEM::Violet::Module::update_credential_state(@_);
}

# Definiert ein VIOLET-Gerät über die ausgelagerte Implementierung.
sub VIOLET_Define($$) {
	return FHEM::Violet::Module::define(@_);
}

# Beendet die VIOLET-Runtime über die ausgelagerte Implementierung.
sub VIOLET_Undef($$) {
	return FHEM::Violet::Module::undefine(@_);
}

# Delegiert globale Lifecycle-Ereignisse an die ausgelagerte Implementierung.
sub VIOLET_Notify($$) {
	return FHEM::Violet::Module::notify(@_);
}

# Validiert Attributänderungen über die ausgelagerte Implementierung.
sub VIOLET_Attr(@) {
	return FHEM::Violet::Module::attr(\%main::defs, @_);
}

1;

=pod

=item device
=item summary PoolDigital VIOLET pool controller integration
=item summary_DE Integration der PoolDigital VIOLET Poolsteuerung

=begin html

<a id="VIOLET" name="VIOLET"></a>
<h3>VIOLET</h3>
<p>Integration einer PoolDigital VIOLET Poolsteuerung ueber die lokale HTTP-API.</p>

<a id="VIOLET-define"></a>
<h4>Define</h4>
<p><b>Syntax:</b></p>
<pre>define &lt;name&gt; VIOLET &lt;host-or-ip&gt;</pre>
<p><b>Beispiel:</b></p>
<pre>define pool VIOLET 192.168.178.55</pre>

<p><b>Kontexthilfe in FHEMWEB:</b> Die normale FHEMWEB-Onlinehilfe wird fuer
VIOLET verwendet. Beim Auswaehlen eines Set-, Get- oder VIOLET-spezifischen
Attribut-Eintrags zeigt FHEMWEB den passenden Abschnitt direkt am jeweiligen
Auswahlfeld an.</p>

<a id="VIOLET-readings"></a>
<h4>Reading-Verhalten</h4>
<p>Controller- und Modulreadings werden nur geschrieben, wenn sich ihr Wert
tatsaechlich geaendert hat. Das Reading <code>state</code> ist die Ausnahme und
wird bei jeder HTTP-Antwort aktualisiert, damit dessen Zeitstempel als
Heartbeat fuer die Device-Ueberwachung verwendet werden kann.</p>
<p>Ein noch nicht existierendes Controller-Reading wird nicht angelegt, wenn
VIOLET dafuer nur einen leeren Wert oder einen numerischen Nullwert
(<code>0</code>, <code>0.0</code>, usw.) liefert. Sobald das Reading einmal mit
einem relevanten Wert existiert, werden spaetere Wechsel auf <code>0</code> oder
leer normal gespeichert.</p>

<a id="VIOLET-attr"></a>
<h4>Attribute</h4>
<ul>
<a id="VIOLET-attr-interval"></a>
<li><b>interval</b><br>
Polling-Intervall in Sekunden. <code>0</code> deaktiviert das zyklische Polling,
aktive Intervalle muessen mindestens 5 Sekunden betragen.<br>
Syntax: <code>attr &lt;name&gt; interval &lt;seconds&gt;</code><br>
Beispiel: <code>attr pool interval 60</code>
</li><br>

<a id="VIOLET-attr-readingsQuery"></a>
<li><b>readingsQuery</b><br>
Optionaler manueller Override fuer die zyklische <code>/getReadings</code>-Abfrage. Ohne Attribut wird <code>/getConfig</code> ausgewertet und
fuer <code>get &lt;name&gt; values</code> ohne explizite Gruppen.<br>
Syntax: <code>attr &lt;name&gt; readingsQuery &lt;GROUP[,GROUP...]&gt;</code><br>
Beispiel:
<code>attr pool readingsQuery ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM</code>
</li><br>

<a id="VIOLET-attr-useSSL"></a>
<li><b>useSSL</b><br>
<code>0</code> verwendet HTTP, <code>1</code> HTTPS.<br>
Syntax: <code>attr &lt;name&gt; useSSL &lt;0|1&gt;</code><br>
Beispiel: <code>attr pool useSSL 1</code>
</li><br>

<a id="VIOLET-attr-port"></a>
<li><b>port</b><br>
Optionaler TCP-Port der VIOLET-API. Gueltiger Bereich: 1..65535.<br>
Syntax: <code>attr &lt;name&gt; port &lt;port&gt;</code><br>
Beispiel: <code>attr pool port 443</code>
</li><br>

<a id="VIOLET-attr-username"></a>
<li><b>username</b><br>
Benutzername fuer HTTP Basic Authentication. Das Passwort wird nicht als
Attribut gespeichert, sondern mit <code>set ... password</code> im
FHEM-KeyValueStore abgelegt.<br>
Syntax: <code>attr &lt;name&gt; username &lt;user&gt;</code><br>
Beispiel: <code>attr pool username admin</code>
</li><br>

<a id="VIOLET-attr-token"></a>
<li><b>token</b><br>
Optionaler Schutz fuer eingehende VIOLET-Pushes. Ohne Attribut ist kein Token
erforderlich. Ist das Attribut gesetzt, muss der Push denselben Token enthalten.<br>
Syntax: <code>attr &lt;name&gt; token &lt;token&gt;</code><br>
Beispiel: <code>attr pool token MeinGeheimerToken</code>
</li><br>

<a id="VIOLET-attr-timeout"></a>
<li><b>timeout</b><br>
HTTP-Timeout fuer Requests an VIOLET in Sekunden.<br>
Syntax: <code>attr &lt;name&gt; timeout &lt;seconds&gt;</code><br>
Beispiel: <code>attr pool timeout 10</code>
</li><br>

<a id="VIOLET-attr-disable"></a>
<li><b>disable</b><br>
Deaktiviert (<code>1</code>) bzw. aktiviert (<code>0</code>) Modulaktivitaet und Polling.<br>
Syntax: <code>attr &lt;name&gt; disable &lt;0|1&gt;</code><br>
Beispiel: <code>attr pool disable 1</code>
</li><br>

<li><a href="#readingFnAttributes">readingFnAttributes</a> -
die allgemeinen FHEM-Readingattribute.</li>
</ul>

<a id="VIOLET-logging"></a>
<h4>Logging</h4>
<p>Das Modul verwendet das normale FHEM-Attribut <code>verbose</code> und
<code>Log3</code>. Ist <code>verbose</code> am VIOLET-Geraet nicht gesetzt, gilt
der globale Wert (FHEM-Standard: <code>3</code>). Die Meldungen sind wie folgt abgestuft:
<code>1</code> nur kritische Fehler, <code>2</code> zusaetzlich Warnungen/Infos,
<code>3</code> allgemeiner Funktionsablauf, <code>4</code> zusaetzlich uebergebene
Variablen und <code>5</code> strukturierte HTTP-Requests/-Responses mit Headern
und auf 8192 Zeichen begrenzten Body-Vorschauen. Passwoerter, Authorization-Header,
Basic-/Bearer-Werte, Cookies, Token, API-Schluessel, Client-Secrets und PSKs werden
vor jeder Ausgabe maskiert.</p>
<p>Beispiel: <code>attr pool verbose 4</code></p>

<a id="VIOLET-set"></a>
<h4>Set</h4>
<ul>

<li><a id="VIOLET-set-password"></a>
<b>password</b><br>
Speichert das VIOLET-Passwort im FHEM-KeyValueStore.<br>
Syntax: <code>set &lt;name&gt; password &lt;password&gt;</code><br>
Beispiel: <code>set pool password MeinPasswort</code>
</li><br>

<li><a id="VIOLET-set-pump"></a>
<b>pump</b><br>
Steuert die Filterpumpe; Laufzeit und Pumpenstufe sind optional.<br>
Syntax: <code>set &lt;name&gt; pump &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool pump on 1800 2</code>
</li><br>

<li><a id="VIOLET-set-solar"></a>
<b>solar</b><br>
Steuert die Solar-/Absorberfunktion.<br>
Syntax: <code>set &lt;name&gt; solar &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool solar auto</code>
</li><br>

<li><a id="VIOLET-set-heater"></a>
<b>heater</b><br>
Steuert die Heizungsfunktion.<br>
Syntax: <code>set &lt;name&gt; heater &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool heater auto</code>
</li><br>

<li><a id="VIOLET-set-eco"></a>
<b>eco</b><br>
Steuert die ECO-Funktion.<br>
Syntax: <code>set &lt;name&gt; eco &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool eco on</code>
</li><br>

<li><a id="VIOLET-set-backwash"></a>
<b>backwash</b><br>
Startet, stoppt oder automatisiert die Rueckspuelfunktion.<br>
Syntax: <code>set &lt;name&gt; backwash &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool backwash on 120</code>
</li><br>

<li><a id="VIOLET-set-rinse"></a>
<b>rinse</b><br>
Startet, stoppt oder automatisiert das Nachspuelen.<br>
Syntax: <code>set &lt;name&gt; rinse &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool rinse on 30</code>
</li><br>

<li><a id="VIOLET-set-refill"></a>
<b>refill</b><br>
Steuert die Wassernachspeisung.<br>
Syntax: <code>set &lt;name&gt; refill &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool refill auto</code>
</li><br>

<li><a id="VIOLET-set-pumpSpeed"></a>
<b>pumpSpeed</b><br>
Schaltet die Filterpumpe auf eine feste Pumpenstufe.<br>
Syntax: <code>set &lt;name&gt; pumpSpeed &lt;1|2|3&gt; [durationSec]</code><br>
Beispiel: <code>set pool pumpSpeed 2 1800</code>
</li><br>

<li><a id="VIOLET-set-light"></a>
<b>light</b><br>
Steuert die Poolbeleuchtung.<br>
Syntax: <code>set &lt;name&gt; light &lt;on|off|auto|color&gt;</code><br>
Beispiel: <code>set pool light auto</code>
</li><br>

<li><a id="VIOLET-set-pvSurplus"></a>
<b>pvSurplus</b><br>
Aktiviert oder deaktiviert den PV-Ueberschussbetrieb; die Pumpenstufe ist optional.<br>
Syntax: <code>set &lt;name&gt; pvSurplus &lt;on|off&gt; [speed 1..3]</code><br>
Beispiel: <code>set pool pvSurplus on 2</code>
</li><br>

<li><a id="VIOLET-set-targetPh"></a>
<b>targetPh</b><br>
Setzt den pH-Sollwert. Punkt und Komma werden als Dezimaltrenner akzeptiert.<br>
Syntax: <code>set &lt;name&gt; targetPh &lt;6.00..8.00&gt;</code><br>
Beispiel: <code>set pool targetPh 7.20</code>
</li><br>

<li><a id="VIOLET-set-targetOrp"></a>
<b>targetOrp</b><br>
Setzt den Redox-/ORP-Sollwert.<br>
Syntax: <code>set &lt;name&gt; targetOrp &lt;500..900&gt;</code><br>
Beispiel: <code>set pool targetOrp 750</code>
</li><br>

<li><a id="VIOLET-set-targetMinChlorine"></a>
<b>targetMinChlorine</b><br>
Setzt den unteren Chlor-Sollwert.<br>
Syntax: <code>set &lt;name&gt; targetMinChlorine &lt;0.00..5.00&gt;</code><br>
Beispiel: <code>set pool targetMinChlorine 0.30</code>
</li><br>

<li><a id="VIOLET-set-targetHeater"></a>
<b>targetHeater</b><br>
Setzt die Solltemperatur der Heizung.<br>
Syntax: <code>set &lt;name&gt; targetHeater &lt;5.0..45.0&gt;</code><br>
Beispiel: <code>set pool targetHeater 28.5</code>
</li><br>

<li><a id="VIOLET-set-targetSolar"></a>
<b>targetSolar</b><br>
Setzt die maximale Zieltemperatur der Solarfunktion.<br>
Syntax: <code>set &lt;name&gt; targetSolar &lt;5.0..55.0&gt;</code><br>
Beispiel: <code>set pool targetSolar 30.5</code>
</li><br>

<li><a id="VIOLET-set-generated-relay" data-pattern="^ext[12]_[1-8]$"></a>
<b>Erweiterungsrelais</b><br>
Steuert genau ein Relais der Erweiterung 1 oder 2.<br>
Syntax: <code>set &lt;name&gt; ext1_1 .. ext2_8 &lt;on|off|auto&gt;</code><br>
Beispiel: <code>set pool ext1_3 on</code>
</li><br>

<li><a id="VIOLET-set-generated-dmx" data-pattern="^dmx(?:[1-9]|1[0-2])$"></a>
<b>DMX-Szene</b><br>
Steuert genau eine DMX-Szene 1..12.<br>
Syntax: <code>set &lt;name&gt; dmx1 .. dmx12 &lt;on|off|auto&gt;</code><br>
Beispiel: <code>set pool dmx7 on</code>
</li><br>

<li><a id="VIOLET-set-dmxAll"></a>
<b>dmxAll</b><br>
Steuert alle DMX-Szenen gemeinsam.<br>
Syntax: <code>set &lt;name&gt; dmxAll &lt;on|off|auto&gt;</code><br>
Beispiel: <code>set pool dmxAll off</code>
</li><br>

<li><a id="VIOLET-set-generated-dirule" data-pattern="^diRule[1-7]$"></a>
<b>Digitaleingangsregel</b><br>
Steuert genau eine Digitaleingangsregel 1..8.<br>
Syntax: <code>set &lt;name&gt; diRule1 .. diRule7 &lt;push|lock|unlock&gt;</code><br>
Beispiel: <code>set pool diRule3 push</code>
</li><br>

<li><a id="VIOLET-set-generated-dose" data-pattern="^dose(?:Chlor|Electrolysis|Phminus|Phplus|Floc)$"></a>
<b>Manuelle Dosierung</b><br>
Startet eine einmalige manuelle Dosierung fuer exakt die angegebene Laufzeit in
Sekunden. VIOLET beendet sie danach selbst und kehrt in den Automatikbetrieb
zurueck. Ein laufender manueller Vorgang kann auf der Kommandozeile weiterhin
mit <code>doseStop &lt;Kanal&gt;</code> bzw. dem Kompatibilitaetsalias
<code>doseStop&lt;Kanal&gt;</code> vorzeitig beendet werden.<br>
Syntax: <code>set &lt;name&gt; dose&lt;Kanal&gt; &lt;seconds&gt;</code><br>
Beispiel: <code>set pool doseChlor 30</code>
</li><br>

<li><a id="VIOLET-set-generated-dosage" data-pattern="^dosage(?:Chlor|Electrolysis|Phminus|Phplus|Floc|H2o2)$"></a>
<b>Dosierfunktion starten/stoppen</b><br>
Aktiviert (<code>start</code>) oder deaktiviert (<code>stop</code>) die automatische
Dosierfunktion des angegebenen Kanals ueber dessen <code>DOSAGE_*_use</code>-Konfiguration.
Das ist nicht die manuelle Dosierung.<br>
Syntax: <code>set &lt;name&gt; dosage&lt;Kanal&gt; &lt;start|stop&gt;</code><br>
Beispiel: <code>set pool dosageChlor start</code>
</li><br>

<li><a id="VIOLET-set-generated-canister-adjust" data-pattern="^canister(?:Chlor|Electrolysis|Phminus|Phplus|Floc)Adjust$"></a>
<b>Kanistermenge korrigieren</b><br>
Syntax: <code>set &lt;name&gt; canister&lt;Kanal&gt;Adjust &lt;ml&gt;</code><br>
Beispiel: <code>set pool canisterChlorAdjust 500</code>
</li><br>

<li><a id="VIOLET-set-generated-canister-reset" data-pattern="^canister(?:Chlor|Electrolysis|Phminus|Phplus|Floc)Reset$"></a>
<b>Kanistermenge setzen/zuruecksetzen</b><br>
Syntax: <code>set &lt;name&gt; canister&lt;Kanal&gt;Reset &lt;ml&gt;</code><br>
Beispiel: <code>set pool canisterChlorReset 20000</code>
</li><br>

<li><a id="VIOLET-set-cover"></a>
<b>cover</b><br>
Steuert die Poolabdeckung.<br>
Syntax: <code>set &lt;name&gt; cover &lt;open|close|stop&gt;</code><br>
Beispiel: <code>set pool cover open</code>
</li><br>

<li><a id="VIOLET-set-omni"></a>
<b>omni</b><br>
Setzt die Omni-Stellantriebsposition.<br>
Syntax: <code>set &lt;name&gt; omni &lt;0..5&gt;</code><br>
Beispiel: <code>set pool omni 2</code>
</li><br>

<li><a id="VIOLET-set-resetBlocking"></a>
<b>resetBlocking</b><br>
Setzt blockierende VIOLET-Zustaende zurueck.<br>
Syntax: <code>set &lt;name&gt; resetBlocking</code><br>
Beispiel: <code>set pool resetBlocking</code>
</li><br>

<li><a id="VIOLET-set-rs485Live"></a>
<b>rs485Live</b><br>
Startet die direkte RS485-Live-Ansteuerung einer Pumpe fuer Test/Inbetriebnahme.<br>
Syntax: <code>set &lt;name&gt; rs485Live &lt;pumpModel&gt; &lt;slaveId 1..247&gt; &lt;rpm|pwr|hz&gt; &lt;value&gt;</code><br>
Beispiel: <code>set pool rs485Live BADU_ECO_DRIVE_II 1 hz 45</code>
</li><br>

<li><a id="VIOLET-set-rs485Done"></a>
<b>rs485Done</b><br>
Beendet den RS485-Live-/Testmodus.<br>
Syntax: <code>set &lt;name&gt; rs485Done</code><br>
Beispiel: <code>set pool rs485Done</code>
</li><br>

<li><a id="VIOLET-set-outputTest"></a>
<b>outputTest</b><br>
Testet einen VIOLET-Ausgang fuer eine optionale Dauer.<br>
Syntax: <code>set &lt;name&gt; outputTest &lt;output&gt; [mode] [durationSec]</code><br>
Beispiel: <code>set pool outputTest PUMP</code>
</li><br>

<li><a id="VIOLET-set-generated-calibration" data-pattern="^calibrationRestore(?:Ph|Orp|Chlor)$"></a>
<b>Kalibrierung wiederherstellen</b><br>
Stellt eine alte Elektrodenkalibrierung anhand ihres Unix-Zeitstempels wieder her.<br>
Syntax: <code>set &lt;name&gt; calibrationRestore&lt;Ph|Orp|Chlor&gt; &lt;unixTimestamp&gt;</code><br>
Beispiel: <code>set pool calibrationRestorePh 1720000000</code>
</li><br>

<li><a id="VIOLET-set-generated-service" data-pattern="^service(?:Ftp|Samba|Ssh|Shairport|Homebridge|Alexa|Tunnel|SupportTunnel)$"></a>
<b>Systemdienst</b><br>
Aktiviert oder deaktiviert genau den im Befehlsnamen angegebenen VIOLET-Dienst.<br>
Syntax: <code>set &lt;name&gt; service&lt;Dienst&gt; &lt;on|off&gt;</code><br>
Beispiel: <code>set pool serviceSsh on</code>
</li><br>

<li><a id="VIOLET-set-firmwareUpdate"></a>
<b>firmwareUpdate</b><br>
Startet das von VIOLET vorgesehene Firmware-Update.<br>
Syntax: <code>set &lt;name&gt; firmwareUpdate</code>
</li><br>

<li><a id="VIOLET-set-reboot"></a>
<b>reboot</b><br>
Startet den VIOLET-Controller neu.<br>
Syntax: <code>set &lt;name&gt; reboot</code>
</li><br>

<li><a id="VIOLET-set-manualBackup"></a>
<b>manualBackup</b><br>
Erstellt ein lokales manuelles VIOLET-Backup.<br>
Syntax: <code>set &lt;name&gt; manualBackup</code>
</li><br>

<li><a id="VIOLET-set-localRestore"></a>
<b>localRestore</b><br>
Stellt ein lokales VIOLET-Backup wieder her.<br>
Syntax: <code>set &lt;name&gt; localRestore &lt;backup&gt;</code>
</li><br>

<li><a id="VIOLET-set-network"></a>
<b>network</b><br>
Setzt Netzwerkparameter ueber die strukturierte VIOLET-Schnittstelle.<br>
Syntax: <code>set &lt;name&gt; network ...</code>
</li><br>

<li><a id="VIOLET-set-networkJson"></a>
<b>networkJson</b><br>
Setzt Netzwerkparameter als JSON.<br>
Syntax: <code>set &lt;name&gt; networkJson &lt;json&gt;</code>
</li><br>

<li><a id="VIOLET-set-timezone"></a>
<b>timezone</b><br>
Setzt die Zeitzone des Controllers.<br>
Syntax: <code>set &lt;name&gt; timezone &lt;timezone&gt;</code><br>
Beispiel: <code>set pool timezone Europe/Berlin</code>
</li><br>

<li><a id="VIOLET-set-function"></a>
<b>function</b><br>
Generischer Zugriff auf eine VIOLET-Ausgangsfunktion.<br>
Syntax: <code>set &lt;name&gt; function &lt;OUTPUT&gt; &lt;ACTION&gt; [value1] [value2]</code>
</li><br>

<li><a id="VIOLET-set-rawGet"></a>
<b>rawGet</b><br>
Generischer GET-Fallback fuer einen VIOLET-API-Pfad.<br>
Syntax: <code>set &lt;name&gt; rawGet &lt;/path?query&gt;</code>
</li><br>

<li><a id="VIOLET-set-rawPost"></a>
<b>rawPost</b><br>
Generischer POST-Fallback fuer einen VIOLET-API-Pfad.<br>
Syntax: <code>set &lt;name&gt; rawPost &lt;/path&gt; &lt;form-data&gt;</code>
</li>

</ul>

<a id="VIOLET-get"></a>
<h4>Get</h4>
<ul>
<a id="VIOLET-get-values"></a>
<li><b>values</b><br>
Liest ohne Parameter automatisch die anhand von <code>/getConfig</code> ermittelten aktiven Funktionen; optional koennen
Gruppen direkt angegeben werden. Das Modul startet keine API-Anfrage und kein Polling, solange nicht <code>username</code> und das per
<code>set ... password</code> gespeicherte Passwort vorhanden sind.<br>
Syntax: <code>get &lt;name&gt; values [GROUP ...]</code><br>
Beispiel: <code>get pool values</code>
</li><br>

<a id="VIOLET-get-valuesGroup"></a>
<li><b>valuesGroup</b><br>
Liest genau eine Gruppe aus
<code>ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM</code>.<br>
Syntax:
<code>get &lt;name&gt; valuesGroup &lt;ALL|DOSAGE|RUNTIMES|PUMPPRIOSTATE|BACKWASH|SYSTEM&gt;</code><br>
Beispiel: <code>get pool valuesGroup DOSAGE</code>
</li><br>

<a id="VIOLET-get-outputs"></a>
<li><b>outputs</b><br>
Liest die Ausgangszustaende und speichert sie als <code>output...</code>-Readings.<br>
Syntax: <code>get &lt;name&gt; outputs</code><br>
Beispiel: <code>get pool outputs</code>
</li><br>

<li>
<a id="VIOLET-get-config"></a>
<b>config</b><br>
Liest die Konfiguration fuer Diagnose/Discovery. Es werden keine <code>config...</code>-Readings angelegt; bekannte Sollwerte werden nur unter ihren fachlichen Namen wie <code>phTarget</code> aktualisiert.<br>
Syntax: <code>get &lt;name&gt; config [KEY ...]</code><br>
Beispiel: <code>get pool config</code>
</li><br>

<li>
<a id="VIOLET-get-configKey"></a>
<b>configKey</b><br>
Liest genau einen Konfigurationsschluessel. Nur bekannte Sollwert-Schluessel aktualisieren ein kanonisches Reading; andere Config-Werte werden nicht als Reading gespeichert.<br>
Syntax: <code>get &lt;name&gt; configKey &lt;KEY&gt;</code><br>
Beispiel: <code>get pool configKey HEATER_set_temp</code>
</li><br>

<a id="VIOLET-get-services"></a>
<li><b>services</b><br>
Liest den Status der VIOLET-Systemdienste.<br>
Syntax: <code>get &lt;name&gt; services</code><br>
Beispiel: <code>get pool services</code>
</li><br>

<a id="VIOLET-get-localBackups"></a>
<li><b>localBackups</b><br>
Liest Metadaten vorhandener lokaler Backups.<br>
Syntax: <code>get &lt;name&gt; localBackups</code><br>
Beispiel: <code>get pool localBackups</code>
</li><br>

<a id="VIOLET-get-updateState"></a>
<li><b>updateState</b><br>
Liest den Firmware-/Updatezustand.<br>
Syntax: <code>get &lt;name&gt; updateState</code><br>
Beispiel: <code>get pool updateState</code>
</li><br>

<a id="VIOLET-get-rs485Data"></a>
<li><b>rs485Data</b><br>
Liest RS485-Pumpendaten fuer ein Pumpenmodell.<br>
Syntax: <code>get &lt;name&gt; rs485Data &lt;pumpModel&gt;</code><br>
Beispiel: <code>get pool rs485Data BADU_ECO_DRIVE_II</code>
</li><br>

<a id="VIOLET-get-raw"></a>
<li><b>raw</b><br>
Fuehrt einen beliebigen GET-Endpunkt aus. Der Response-Body wird absichtlich
nicht als Reading gespeichert.<br>
Syntax: <code>get &lt;name&gt; raw &lt;/path?query&gt;</code><br>
Beispiel: <code>get pool raw /getUpdateState</code>
</li>
</ul>

<h4>Reading-Namen</h4>
<p>Alle API-Namen werden konsequent in lowerCamelCase umgewandelt. Messwerte
verwenden kurze Namen; ein abschliessendes <code>Value</code> wird entfernt und
<code>ValueMin</code>/<code>ValueMax</code> wird zu <code>Min</code>/<code>Max</code>:</p>
<pre>
pH_value       -> ph
pH_value_min   -> phMin
pH_value_max   -> phMax
ORP_value      -> orp
ORP_value_min  -> orpMin
ORP_value_max  -> orpMax
pot_value      -> chlor
pot_value_min  -> chlorMin
pot_value_max  -> chlorMax
</pre>
<p>Sollwerte heissen <code>...Target</code>:</p>
<pre>
DOSAGE_phminus_setpoint          -> phTarget
DOSAGE_chlorine_setpoint_orp     -> orpTarget
DOSAGE_chlorine_lowerval_cl      -> chlorMinTarget
HEATER_set_temp                  -> heaterTarget
SOLAR_maxtemp                    -> solarTarget
</pre>
<p>Dosierkanaele verwenden dieselben Namen wie die Set-Befehle:</p>
<pre>
DOS_1_CL_...   -> dosageChlor...
DOS_2_ELO_...  -> dosageElectrolysis...
DOS_4_PHM_...  -> dosagePhminus...
DOS_5_PHP_...  -> dosagePhplus...
DOS_6_FLOC_... -> dosageFloc...
</pre>
<p>Andere API-Bereiche erhalten camelCase-Praefixe ohne Unterstrich, z.B.
<code>outputPump</code>, <code>configFooBar</code>, <code>serviceSsh</code>,
<code>backup...</code>, <code>update...</code> und <code>rs485...</code>.</p>

<h4>HTTP-Push von VIOLET</h4>
<p>Ohne Token:</p>
<pre>http://FHEM-IP:8083/fhem/VIOLET?device=pool</pre>
<p>Mit gesetztem <code>attr pool token MEINTOKEN</code>:</p>
<pre>http://FHEM-IP:8083/fhem/VIOLET?device=pool&amp;token=MEINTOKEN</pre>
<p>Gepushte VIOLET-Werte durchlaufen exakt dasselbe Reading-Mapping wie
<code>get ... values</code>. Ein Push von <code>pH_value</code> aktualisiert also
<code>ph</code> und erzeugt kein separates Push-Messwert-Reading. Nur technische
Push-Metadaten wie <code>pushAuthState</code> und <code>pushLast</code> bleiben separat.</p>

=end html

=begin html_DE

<a id="VIOLET" name="VIOLET"></a>
<h3>VIOLET</h3>
<p>Integration einer PoolDigital VIOLET Poolsteuerung ueber die lokale HTTP-API.</p>

<a id="VIOLET-define"></a>
<h4>Define</h4>
<p><b>Syntax:</b></p>
<pre>define &lt;name&gt; VIOLET &lt;host-or-ip&gt;</pre>
<p><b>Beispiel:</b></p>
<pre>define pool VIOLET 192.168.178.55</pre>

<p><b>Kontexthilfe in FHEMWEB:</b> Die normale FHEMWEB-Onlinehilfe wird fuer
VIOLET verwendet. Beim Auswaehlen eines Set-, Get- oder VIOLET-spezifischen
Attribut-Eintrags zeigt FHEMWEB den passenden Abschnitt direkt am jeweiligen
Auswahlfeld an.</p>

<a id="VIOLET-readings"></a>
<h4>Reading-Verhalten</h4>
<p>Controller- und Modulreadings werden nur geschrieben, wenn sich ihr Wert
tatsaechlich geaendert hat. Das Reading <code>state</code> ist die Ausnahme und
wird bei jeder HTTP-Antwort aktualisiert, damit dessen Zeitstempel als
Heartbeat fuer die Device-Ueberwachung verwendet werden kann.</p>
<p>Ein noch nicht existierendes Controller-Reading wird nicht angelegt, wenn
VIOLET dafuer nur einen leeren Wert oder einen numerischen Nullwert
(<code>0</code>, <code>0.0</code>, usw.) liefert. Sobald das Reading einmal mit
einem relevanten Wert existiert, werden spaetere Wechsel auf <code>0</code> oder
leer normal gespeichert.</p>

<a id="VIOLET-attr"></a>
<h4>Attribute</h4>
<ul>
<a id="VIOLET-attr-interval"></a>
<li><b>interval</b><br>
Polling-Intervall in Sekunden. <code>0</code> deaktiviert das zyklische Polling,
aktive Intervalle muessen mindestens 5 Sekunden betragen.<br>
Syntax: <code>attr &lt;name&gt; interval &lt;seconds&gt;</code><br>
Beispiel: <code>attr pool interval 60</code>
</li><br>

<a id="VIOLET-attr-readingsQuery"></a>
<li><b>readingsQuery</b><br>
Optionaler manueller Override fuer die zyklische <code>/getReadings</code>-Abfrage. Ohne Attribut wird <code>/getConfig</code> ausgewertet und
fuer <code>get &lt;name&gt; values</code> ohne explizite Gruppen.<br>
Syntax: <code>attr &lt;name&gt; readingsQuery &lt;GROUP[,GROUP...]&gt;</code><br>
Beispiel:
<code>attr pool readingsQuery ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM</code>
</li><br>

<a id="VIOLET-attr-useSSL"></a>
<li><b>useSSL</b><br>
<code>0</code> verwendet HTTP, <code>1</code> HTTPS.<br>
Syntax: <code>attr &lt;name&gt; useSSL &lt;0|1&gt;</code><br>
Beispiel: <code>attr pool useSSL 1</code>
</li><br>

<a id="VIOLET-attr-port"></a>
<li><b>port</b><br>
Optionaler TCP-Port der VIOLET-API. Gueltiger Bereich: 1..65535.<br>
Syntax: <code>attr &lt;name&gt; port &lt;port&gt;</code><br>
Beispiel: <code>attr pool port 443</code>
</li><br>

<a id="VIOLET-attr-username"></a>
<li><b>username</b><br>
Benutzername fuer HTTP Basic Authentication. Das Passwort wird nicht als
Attribut gespeichert, sondern mit <code>set ... password</code> im
FHEM-KeyValueStore abgelegt.<br>
Syntax: <code>attr &lt;name&gt; username &lt;user&gt;</code><br>
Beispiel: <code>attr pool username admin</code>
</li><br>

<a id="VIOLET-attr-token"></a>
<li><b>token</b><br>
Optionaler Schutz fuer eingehende VIOLET-Pushes. Ohne Attribut ist kein Token
erforderlich. Ist das Attribut gesetzt, muss der Push denselben Token enthalten.<br>
Syntax: <code>attr &lt;name&gt; token &lt;token&gt;</code><br>
Beispiel: <code>attr pool token MeinGeheimerToken</code>
</li><br>

<a id="VIOLET-attr-timeout"></a>
<li><b>timeout</b><br>
HTTP-Timeout fuer Requests an VIOLET in Sekunden.<br>
Syntax: <code>attr &lt;name&gt; timeout &lt;seconds&gt;</code><br>
Beispiel: <code>attr pool timeout 10</code>
</li><br>

<a id="VIOLET-attr-disable"></a>
<li><b>disable</b><br>
Deaktiviert (<code>1</code>) bzw. aktiviert (<code>0</code>) Modulaktivitaet und Polling.<br>
Syntax: <code>attr &lt;name&gt; disable &lt;0|1&gt;</code><br>
Beispiel: <code>attr pool disable 1</code>
</li><br>

<li><a href="#readingFnAttributes">readingFnAttributes</a> -
die allgemeinen FHEM-Readingattribute.</li>
</ul>

<a id="VIOLET-logging"></a>
<h4>Logging</h4>
<p>Das Modul verwendet das normale FHEM-Attribut <code>verbose</code> und
<code>Log3</code>. Ist <code>verbose</code> am VIOLET-Geraet nicht gesetzt, gilt
der globale Wert (FHEM-Standard: <code>3</code>). Die Meldungen sind wie folgt abgestuft:
<code>1</code> nur kritische Fehler, <code>2</code> zusaetzlich Warnungen/Infos,
<code>3</code> allgemeiner Funktionsablauf, <code>4</code> zusaetzlich uebergebene
Variablen und <code>5</code> strukturierte HTTP-Requests/-Responses mit Headern
und auf 8192 Zeichen begrenzten Body-Vorschauen. Passwoerter, Authorization-Header,
Basic-/Bearer-Werte, Cookies, Token, API-Schluessel, Client-Secrets und PSKs werden
vor jeder Ausgabe maskiert.</p>
<p>Beispiel: <code>attr pool verbose 4</code></p>

<a id="VIOLET-set"></a>
<h4>Set</h4>
<ul>

<li><a id="VIOLET-set-password"></a>
<b>password</b><br>
Speichert das VIOLET-Passwort im FHEM-KeyValueStore.<br>
Syntax: <code>set &lt;name&gt; password &lt;password&gt;</code><br>
Beispiel: <code>set pool password MeinPasswort</code>
</li><br>

<li><a id="VIOLET-set-pump"></a>
<b>pump</b><br>
Steuert die Filterpumpe; Laufzeit und Pumpenstufe sind optional.<br>
Syntax: <code>set &lt;name&gt; pump &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool pump on 1800 2</code>
</li><br>

<li><a id="VIOLET-set-solar"></a>
<b>solar</b><br>
Steuert die Solar-/Absorberfunktion.<br>
Syntax: <code>set &lt;name&gt; solar &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool solar auto</code>
</li><br>

<li><a id="VIOLET-set-heater"></a>
<b>heater</b><br>
Steuert die Heizungsfunktion.<br>
Syntax: <code>set &lt;name&gt; heater &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool heater auto</code>
</li><br>

<li><a id="VIOLET-set-eco"></a>
<b>eco</b><br>
Steuert die ECO-Funktion.<br>
Syntax: <code>set &lt;name&gt; eco &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool eco on</code>
</li><br>

<li><a id="VIOLET-set-backwash"></a>
<b>backwash</b><br>
Startet, stoppt oder automatisiert die Rueckspuelfunktion.<br>
Syntax: <code>set &lt;name&gt; backwash &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool backwash on 120</code>
</li><br>

<li><a id="VIOLET-set-rinse"></a>
<b>rinse</b><br>
Startet, stoppt oder automatisiert das Nachspuelen.<br>
Syntax: <code>set &lt;name&gt; rinse &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool rinse on 30</code>
</li><br>

<li><a id="VIOLET-set-refill"></a>
<b>refill</b><br>
Steuert die Wassernachspeisung.<br>
Syntax: <code>set &lt;name&gt; refill &lt;on|off|auto&gt; [durationSec] [speed 0..3]</code><br>
Beispiel: <code>set pool refill auto</code>
</li><br>

<li><a id="VIOLET-set-pumpSpeed"></a>
<b>pumpSpeed</b><br>
Schaltet die Filterpumpe auf eine feste Pumpenstufe.<br>
Syntax: <code>set &lt;name&gt; pumpSpeed &lt;1|2|3&gt; [durationSec]</code><br>
Beispiel: <code>set pool pumpSpeed 2 1800</code>
</li><br>

<li><a id="VIOLET-set-light"></a>
<b>light</b><br>
Steuert die Poolbeleuchtung.<br>
Syntax: <code>set &lt;name&gt; light &lt;on|off|auto|color&gt;</code><br>
Beispiel: <code>set pool light auto</code>
</li><br>

<li><a id="VIOLET-set-pvSurplus"></a>
<b>pvSurplus</b><br>
Aktiviert oder deaktiviert den PV-Ueberschussbetrieb; die Pumpenstufe ist optional.<br>
Syntax: <code>set &lt;name&gt; pvSurplus &lt;on|off&gt; [speed 1..3]</code><br>
Beispiel: <code>set pool pvSurplus on 2</code>
</li><br>

<li><a id="VIOLET-set-targetPh"></a>
<b>targetPh</b><br>
Setzt den pH-Sollwert. Punkt und Komma werden als Dezimaltrenner akzeptiert.<br>
Syntax: <code>set &lt;name&gt; targetPh &lt;6.00..8.00&gt;</code><br>
Beispiel: <code>set pool targetPh 7.20</code>
</li><br>

<li><a id="VIOLET-set-targetOrp"></a>
<b>targetOrp</b><br>
Setzt den Redox-/ORP-Sollwert.<br>
Syntax: <code>set &lt;name&gt; targetOrp &lt;500..900&gt;</code><br>
Beispiel: <code>set pool targetOrp 750</code>
</li><br>

<li><a id="VIOLET-set-targetMinChlorine"></a>
<b>targetMinChlorine</b><br>
Setzt den unteren Chlor-Sollwert.<br>
Syntax: <code>set &lt;name&gt; targetMinChlorine &lt;0.00..5.00&gt;</code><br>
Beispiel: <code>set pool targetMinChlorine 0.30</code>
</li><br>

<li><a id="VIOLET-set-targetHeater"></a>
<b>targetHeater</b><br>
Setzt die Solltemperatur der Heizung.<br>
Syntax: <code>set &lt;name&gt; targetHeater &lt;5.0..45.0&gt;</code><br>
Beispiel: <code>set pool targetHeater 28.5</code>
</li><br>

<li><a id="VIOLET-set-targetSolar"></a>
<b>targetSolar</b><br>
Setzt die maximale Zieltemperatur der Solarfunktion.<br>
Syntax: <code>set &lt;name&gt; targetSolar &lt;5.0..55.0&gt;</code><br>
Beispiel: <code>set pool targetSolar 30.5</code>
</li><br>

<li><a id="VIOLET-set-generated-relay" data-pattern="^ext[12]_[1-8]$"></a>
<b>Erweiterungsrelais</b><br>
Steuert genau ein Relais der Erweiterung 1 oder 2.<br>
Syntax: <code>set &lt;name&gt; ext1_1 .. ext2_8 &lt;on|off|auto&gt;</code><br>
Beispiel: <code>set pool ext1_3 on</code>
</li><br>

<li><a id="VIOLET-set-generated-dmx" data-pattern="^dmx(?:[1-9]|1[0-2])$"></a>
<b>DMX-Szene</b><br>
Steuert genau eine DMX-Szene 1..12.<br>
Syntax: <code>set &lt;name&gt; dmx1 .. dmx12 &lt;on|off|auto&gt;</code><br>
Beispiel: <code>set pool dmx7 on</code>
</li><br>

<li><a id="VIOLET-set-dmxAll"></a>
<b>dmxAll</b><br>
Steuert alle DMX-Szenen gemeinsam.<br>
Syntax: <code>set &lt;name&gt; dmxAll &lt;on|off|auto&gt;</code><br>
Beispiel: <code>set pool dmxAll off</code>
</li><br>

<li><a id="VIOLET-set-generated-dirule" data-pattern="^diRule[1-7]$"></a>
<b>Digitaleingangsregel</b><br>
Steuert genau eine Digitaleingangsregel 1..8.<br>
Syntax: <code>set &lt;name&gt; diRule1 .. diRule7 &lt;push|lock|unlock&gt;</code><br>
Beispiel: <code>set pool diRule3 push</code>
</li><br>

<li><a id="VIOLET-set-generated-dose" data-pattern="^dose(?:Chlor|Electrolysis|Phminus|Phplus|Floc)$"></a>
<b>Manuelle Dosierung</b><br>
Startet eine einmalige manuelle Dosierung fuer exakt die angegebene Laufzeit in
Sekunden. VIOLET beendet sie danach selbst und kehrt in den Automatikbetrieb
zurueck. Ein laufender manueller Vorgang kann auf der Kommandozeile weiterhin
mit <code>doseStop &lt;Kanal&gt;</code> bzw. dem Kompatibilitaetsalias
<code>doseStop&lt;Kanal&gt;</code> vorzeitig beendet werden.<br>
Syntax: <code>set &lt;name&gt; dose&lt;Kanal&gt; &lt;seconds&gt;</code><br>
Beispiel: <code>set pool doseChlor 30</code>
</li><br>

<li><a id="VIOLET-set-generated-dosage" data-pattern="^dosage(?:Chlor|Electrolysis|Phminus|Phplus|Floc|H2o2)$"></a>
<b>Dosierfunktion starten/stoppen</b><br>
Aktiviert (<code>start</code>) oder deaktiviert (<code>stop</code>) die automatische
Dosierfunktion des angegebenen Kanals ueber dessen <code>DOSAGE_*_use</code>-Konfiguration.
Das ist nicht die manuelle Dosierung.<br>
Syntax: <code>set &lt;name&gt; dosage&lt;Kanal&gt; &lt;start|stop&gt;</code><br>
Beispiel: <code>set pool dosageChlor start</code>
</li><br>

<li><a id="VIOLET-set-generated-canister-adjust" data-pattern="^canister(?:Chlor|Electrolysis|Phminus|Phplus|Floc)Adjust$"></a>
<b>Kanistermenge korrigieren</b><br>
Syntax: <code>set &lt;name&gt; canister&lt;Kanal&gt;Adjust &lt;ml&gt;</code><br>
Beispiel: <code>set pool canisterChlorAdjust 500</code>
</li><br>

<li><a id="VIOLET-set-generated-canister-reset" data-pattern="^canister(?:Chlor|Electrolysis|Phminus|Phplus|Floc)Reset$"></a>
<b>Kanistermenge setzen/zuruecksetzen</b><br>
Syntax: <code>set &lt;name&gt; canister&lt;Kanal&gt;Reset &lt;ml&gt;</code><br>
Beispiel: <code>set pool canisterChlorReset 20000</code>
</li><br>

<li><a id="VIOLET-set-cover"></a>
<b>cover</b><br>
Steuert die Poolabdeckung.<br>
Syntax: <code>set &lt;name&gt; cover &lt;open|close|stop&gt;</code><br>
Beispiel: <code>set pool cover open</code>
</li><br>

<li><a id="VIOLET-set-omni"></a>
<b>omni</b><br>
Setzt die Omni-Stellantriebsposition.<br>
Syntax: <code>set &lt;name&gt; omni &lt;0..5&gt;</code><br>
Beispiel: <code>set pool omni 2</code>
</li><br>

<li><a id="VIOLET-set-resetBlocking"></a>
<b>resetBlocking</b><br>
Setzt blockierende VIOLET-Zustaende zurueck.<br>
Syntax: <code>set &lt;name&gt; resetBlocking</code><br>
Beispiel: <code>set pool resetBlocking</code>
</li><br>

<li><a id="VIOLET-set-rs485Live"></a>
<b>rs485Live</b><br>
Startet die direkte RS485-Live-Ansteuerung einer Pumpe fuer Test/Inbetriebnahme.<br>
Syntax: <code>set &lt;name&gt; rs485Live &lt;pumpModel&gt; &lt;slaveId 1..247&gt; &lt;rpm|pwr|hz&gt; &lt;value&gt;</code><br>
Beispiel: <code>set pool rs485Live BADU_ECO_DRIVE_II 1 hz 45</code>
</li><br>

<li><a id="VIOLET-set-rs485Done"></a>
<b>rs485Done</b><br>
Beendet den RS485-Live-/Testmodus.<br>
Syntax: <code>set &lt;name&gt; rs485Done</code><br>
Beispiel: <code>set pool rs485Done</code>
</li><br>

<li><a id="VIOLET-set-outputTest"></a>
<b>outputTest</b><br>
Testet einen VIOLET-Ausgang fuer eine optionale Dauer.<br>
Syntax: <code>set &lt;name&gt; outputTest &lt;output&gt; [mode] [durationSec]</code><br>
Beispiel: <code>set pool outputTest PUMP</code>
</li><br>

<li><a id="VIOLET-set-generated-calibration" data-pattern="^calibrationRestore(?:Ph|Orp|Chlor)$"></a>
<b>Kalibrierung wiederherstellen</b><br>
Stellt eine alte Elektrodenkalibrierung anhand ihres Unix-Zeitstempels wieder her.<br>
Syntax: <code>set &lt;name&gt; calibrationRestore&lt;Ph|Orp|Chlor&gt; &lt;unixTimestamp&gt;</code><br>
Beispiel: <code>set pool calibrationRestorePh 1720000000</code>
</li><br>

<li><a id="VIOLET-set-generated-service" data-pattern="^service(?:Ftp|Samba|Ssh|Shairport|Homebridge|Alexa|Tunnel|SupportTunnel)$"></a>
<b>Systemdienst</b><br>
Aktiviert oder deaktiviert genau den im Befehlsnamen angegebenen VIOLET-Dienst.<br>
Syntax: <code>set &lt;name&gt; service&lt;Dienst&gt; &lt;on|off&gt;</code><br>
Beispiel: <code>set pool serviceSsh on</code>
</li><br>

<li><a id="VIOLET-set-firmwareUpdate"></a>
<b>firmwareUpdate</b><br>
Startet das von VIOLET vorgesehene Firmware-Update.<br>
Syntax: <code>set &lt;name&gt; firmwareUpdate</code>
</li><br>

<li><a id="VIOLET-set-reboot"></a>
<b>reboot</b><br>
Startet den VIOLET-Controller neu.<br>
Syntax: <code>set &lt;name&gt; reboot</code>
</li><br>

<li><a id="VIOLET-set-manualBackup"></a>
<b>manualBackup</b><br>
Erstellt ein lokales manuelles VIOLET-Backup.<br>
Syntax: <code>set &lt;name&gt; manualBackup</code>
</li><br>

<li><a id="VIOLET-set-localRestore"></a>
<b>localRestore</b><br>
Stellt ein lokales VIOLET-Backup wieder her.<br>
Syntax: <code>set &lt;name&gt; localRestore &lt;backup&gt;</code>
</li><br>

<li><a id="VIOLET-set-network"></a>
<b>network</b><br>
Setzt Netzwerkparameter ueber die strukturierte VIOLET-Schnittstelle.<br>
Syntax: <code>set &lt;name&gt; network ...</code>
</li><br>

<li><a id="VIOLET-set-networkJson"></a>
<b>networkJson</b><br>
Setzt Netzwerkparameter als JSON.<br>
Syntax: <code>set &lt;name&gt; networkJson &lt;json&gt;</code>
</li><br>

<li><a id="VIOLET-set-timezone"></a>
<b>timezone</b><br>
Setzt die Zeitzone des Controllers.<br>
Syntax: <code>set &lt;name&gt; timezone &lt;timezone&gt;</code><br>
Beispiel: <code>set pool timezone Europe/Berlin</code>
</li><br>

<li><a id="VIOLET-set-function"></a>
<b>function</b><br>
Generischer Zugriff auf eine VIOLET-Ausgangsfunktion.<br>
Syntax: <code>set &lt;name&gt; function &lt;OUTPUT&gt; &lt;ACTION&gt; [value1] [value2]</code>
</li><br>

<li><a id="VIOLET-set-rawGet"></a>
<b>rawGet</b><br>
Generischer GET-Fallback fuer einen VIOLET-API-Pfad.<br>
Syntax: <code>set &lt;name&gt; rawGet &lt;/path?query&gt;</code>
</li><br>

<li><a id="VIOLET-set-rawPost"></a>
<b>rawPost</b><br>
Generischer POST-Fallback fuer einen VIOLET-API-Pfad.<br>
Syntax: <code>set &lt;name&gt; rawPost &lt;/path&gt; &lt;form-data&gt;</code>
</li>

</ul>

<a id="VIOLET-get"></a>
<h4>Get</h4>
<ul>
<a id="VIOLET-get-values"></a>
<li><b>values</b><br>
Liest ohne Parameter automatisch die anhand von <code>/getConfig</code> ermittelten aktiven Funktionen; optional koennen
Gruppen direkt angegeben werden. Das Modul startet keine API-Anfrage und kein Polling, solange nicht <code>username</code> und das per
<code>set ... password</code> gespeicherte Passwort vorhanden sind.<br>
Syntax: <code>get &lt;name&gt; values [GROUP ...]</code><br>
Beispiel: <code>get pool values</code>
</li><br>

<a id="VIOLET-get-valuesGroup"></a>
<li><b>valuesGroup</b><br>
Liest genau eine Gruppe aus
<code>ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM</code>.<br>
Syntax:
<code>get &lt;name&gt; valuesGroup &lt;ALL|DOSAGE|RUNTIMES|PUMPPRIOSTATE|BACKWASH|SYSTEM&gt;</code><br>
Beispiel: <code>get pool valuesGroup DOSAGE</code>
</li><br>

<a id="VIOLET-get-outputs"></a>
<li><b>outputs</b><br>
Liest die Ausgangszustaende und speichert sie als <code>output...</code>-Readings.<br>
Syntax: <code>get &lt;name&gt; outputs</code><br>
Beispiel: <code>get pool outputs</code>
</li><br>

<li>
<a id="VIOLET-get-config"></a>
<b>config</b><br>
Liest die Konfiguration fuer Diagnose/Discovery. Es werden keine <code>config...</code>-Readings angelegt; bekannte Sollwerte werden nur unter ihren fachlichen Namen wie <code>phTarget</code> aktualisiert.<br>
Syntax: <code>get &lt;name&gt; config [KEY ...]</code><br>
Beispiel: <code>get pool config</code>
</li><br>

<li>
<a id="VIOLET-get-configKey"></a>
<b>configKey</b><br>
Liest genau einen Konfigurationsschluessel. Nur bekannte Sollwert-Schluessel aktualisieren ein kanonisches Reading; andere Config-Werte werden nicht als Reading gespeichert.<br>
Syntax: <code>get &lt;name&gt; configKey &lt;KEY&gt;</code><br>
Beispiel: <code>get pool configKey HEATER_set_temp</code>
</li><br>

<a id="VIOLET-get-services"></a>
<li><b>services</b><br>
Liest den Status der VIOLET-Systemdienste.<br>
Syntax: <code>get &lt;name&gt; services</code><br>
Beispiel: <code>get pool services</code>
</li><br>

<a id="VIOLET-get-localBackups"></a>
<li><b>localBackups</b><br>
Liest Metadaten vorhandener lokaler Backups.<br>
Syntax: <code>get &lt;name&gt; localBackups</code><br>
Beispiel: <code>get pool localBackups</code>
</li><br>

<a id="VIOLET-get-updateState"></a>
<li><b>updateState</b><br>
Liest den Firmware-/Updatezustand.<br>
Syntax: <code>get &lt;name&gt; updateState</code><br>
Beispiel: <code>get pool updateState</code>
</li><br>

<a id="VIOLET-get-rs485Data"></a>
<li><b>rs485Data</b><br>
Liest RS485-Pumpendaten fuer ein Pumpenmodell.<br>
Syntax: <code>get &lt;name&gt; rs485Data &lt;pumpModel&gt;</code><br>
Beispiel: <code>get pool rs485Data BADU_ECO_DRIVE_II</code>
</li><br>

<a id="VIOLET-get-raw"></a>
<li><b>raw</b><br>
Fuehrt einen beliebigen GET-Endpunkt aus. Der Response-Body wird absichtlich
nicht als Reading gespeichert.<br>
Syntax: <code>get &lt;name&gt; raw &lt;/path?query&gt;</code><br>
Beispiel: <code>get pool raw /getUpdateState</code>
</li>
</ul>

<h4>Reading-Namen</h4>
<p>Alle API-Namen werden konsequent in lowerCamelCase umgewandelt. Messwerte
verwenden kurze Namen; ein abschliessendes <code>Value</code> wird entfernt und
<code>ValueMin</code>/<code>ValueMax</code> wird zu <code>Min</code>/<code>Max</code>:</p>
<pre>
pH_value       -> ph
pH_value_min   -> phMin
pH_value_max   -> phMax
ORP_value      -> orp
ORP_value_min  -> orpMin
ORP_value_max  -> orpMax
pot_value      -> chlor
pot_value_min  -> chlorMin
pot_value_max  -> chlorMax
</pre>
<p>Sollwerte heissen <code>...Target</code>:</p>
<pre>
DOSAGE_phminus_setpoint          -> phTarget
DOSAGE_chlorine_setpoint_orp     -> orpTarget
DOSAGE_chlorine_lowerval_cl      -> chlorMinTarget
HEATER_set_temp                  -> heaterTarget
SOLAR_maxtemp                    -> solarTarget
</pre>
<p>Dosierkanaele verwenden dieselben Namen wie die Set-Befehle:</p>
<pre>
DOS_1_CL_...   -> dosageChlor...
DOS_2_ELO_...  -> dosageElectrolysis...
DOS_4_PHM_...  -> dosagePhminus...
DOS_5_PHP_...  -> dosagePhplus...
DOS_6_FLOC_... -> dosageFloc...
</pre>
<p>Andere API-Bereiche erhalten camelCase-Praefixe ohne Unterstrich, z.B.
<code>outputPump</code>, <code>configFooBar</code>, <code>serviceSsh</code>,
<code>backup...</code>, <code>update...</code> und <code>rs485...</code>.</p>

<h4>HTTP-Push von VIOLET</h4>
<p>Ohne Token:</p>
<pre>http://FHEM-IP:8083/fhem/VIOLET?device=pool</pre>
<p>Mit gesetztem <code>attr pool token MEINTOKEN</code>:</p>
<pre>http://FHEM-IP:8083/fhem/VIOLET?device=pool&amp;token=MEINTOKEN</pre>
<p>Gepushte VIOLET-Werte durchlaufen exakt dasselbe Reading-Mapping wie
<code>get ... values</code>. Ein Push von <code>pH_value</code> aktualisiert also
<code>ph</code> und erzeugt kein separates Push-Messwert-Reading. Nur technische
Push-Metadaten wie <code>pushAuthState</code> und <code>pushLast</code> bleiben separat.</p>

=end html_DE

=cut
