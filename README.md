# fhemViolet

`fhemViolet` bindet die Poolsteuerung PoolDigital VIOLET über ihre lokale HTTP-API direkt in FHEM ein. Das Modul liest Messwerte und Betriebszustände, erkennt die konfigurierte Anlagenausstattung und stellt dazu passende `set`- und `get`-Befehle bereit. VIOLET kann Änderungen zusätzlich per HTTP-Push an FHEM senden.

> Dieses Projekt ist keine offizielle PoolDigital-Integration. Änderungen an Firmware oder API können die Funktion beeinflussen.

## Architektur

```text
PoolDigital VIOLET
        |
        +-- lokale HTTP-API (Polling, Get und Set)
        |
        +-- HTTP-Push
        |
        v
FHEM/50_Violet.pm
		|
		+-- dünner FHEM-Wrapper und FHEMWEB-Commandref
		|
		v
lib/FHEM/Violet/Module.pm
		|
		+-- Lifecycle, Attribute und Zugangsdatenstatus
		+-- Commands, Discovery, Transport und Readings
		+-- nebenwirkungsfreie Helpers und Fehler-Metadaten
```

Die Kommunikation erfolgt lokal zwischen FHEM und VIOLET. Für den normalen Betrieb ist kein zusätzlicher Daemon und kein externer Cloud-Dienst erforderlich.

## Funktionen

- automatische Erkennung der in VIOLET konfigurierten Funktionen
- Steuerung von Pumpe, Heizung, Solar, Rückspülung, Nachspülung, Nachspeisung, Licht, Abdeckung und weiteren Ausgängen
- Sollwerte für pH, ORP, Chlor, Heizung und Solar
- Dosierfunktionen, manuelle Dosierung und Kanisterverwaltung
- Unterstützung für Erweiterungsrelais, DMX-Szenen und Digitaleingangsregeln
- Diagnose-, Service-, Backup-, RS485- und Firmwarefunktionen
- generische Raw-Befehle für noch nicht speziell abgebildete API-Endpunkte

Das Modul basiert auf VIOLET-Software 1.1.9, der API-Referenz 05/2026 und dem Stand des Projekts `violet-poolController-api` vom 9. August 2026.

## Installation

Folgende Befehle nacheinander in der FHEM-Kommandozeile ausführen:

```text
update all https://raw.githubusercontent.com/next81/fhemViolet/main/controls_violet.txt
update add https://raw.githubusercontent.com/next81/fhemViolet/main/controls_violet.txt
shutdown restart
```

Der erste Befehl installiert den FHEM-Adapter und alle ausgelagerten Laufzeitmodule direkt aus diesem Repository. `update add` nimmt das Repository zusätzlich in die normale FHEM-Updateprüfung auf. Der anschließende Neustart stellt sicher, dass alle Perl-Module neu geladen werden.

Spätere Aktualisierungen erfolgen über die normalen FHEM-Updatebefehle:

```text
update check
update
shutdown restart
```

## FHEM-Konfiguration

Gerät definieren und Benutzernamen setzen:

```text
define pool VIOLET 192.168.178.55
attr pool username admin
set pool password MeinPasswort
```

Eine typische Grundkonfiguration sieht so aus:

```text
define pool VIOLET 192.168.178.55
attr pool username admin
attr pool interval 60
attr pool timeout 10
attr pool useSSL 0
set pool password MeinPasswort
```

Das Modul sendet keine API-Anfrage und startet kein Polling, solange Benutzername und Passwort nicht vollständig vorhanden sind. Nach einer HTTP-Antwort mit Status 401 oder 403 bleibt die Anmeldung gesperrt, bis Benutzername oder Passwort geändert wurden.

Relevante Zustände sind unter anderem:

| Reading/Zustand | Bedeutung |
|---|---|
| `missing_username` | der Benutzername fehlt |
| `missing_password` | im KeyValueStore ist kein Passwort hinterlegt |
| `authenticating` | Zugangsdaten sind vollständig, aber noch nicht bestätigt |
| `accepted` | die Zugangsdaten wurden erfolgreich verwendet |
| `auth_rejected` | VIOLET hat die Anmeldung mit 401 oder 403 abgelehnt |
| `storage_error` | der FHEM-KeyValueStore konnte nicht gelesen werden |

## Attribute

| Attribut | Standard | Beschreibung |
|---|---:|---|
| `interval` | `60` | Polling-Intervall in Sekunden; `0` deaktiviert Polling, aktive Werte müssen mindestens 5 Sekunden betragen |
| `readingsQuery` | automatisch | manueller Override der Gruppen für `/getReadings`, kommasepariert |
| `useSSL` | `0` | `0` für HTTP, `1` für HTTPS |
| `port` | protokollabhängig | optionaler TCP-Port von 1 bis 65535 |
| `username` | – | Benutzername für HTTP Basic Authentication |
| `token` | – | optionaler gemeinsamer Token für eingehende HTTP-Pushes |
| `timeout` | `10` | HTTP-Timeout in Sekunden |
| `disable` | `0` | deaktiviert mit `1` Modulaktivität und Polling |
| `verbose` | FHEM-Standard | steuert den Detailgrad der Protokollierung |

Ein manueller `readingsQuery`-Override kann beispielsweise so gesetzt werden:

```text
attr pool readingsQuery ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM
```

Ohne dieses Attribut ermittelt das Modul die erforderlichen Gruppen selbst.

## Automatische Erkennung

Nach erfolgreicher Anmeldung liest das Modul, welche Messkanäle und Funktionen tatsächlich vorhanden sind. Daraus entstehen:

- eine an die Anlage angepasste Polling-Abfrage,
- eine dynamische Liste sinnvoller `set`-Befehle,
- nur die Readings, die von der Steuerung mit relevanten Werten geliefert werden.

Inaktive Platzhalterkanäle werden herausgefiltert. Ein noch nicht existierendes Controller-Reading wird außerdem nicht nur wegen eines leeren Werts oder eines numerischen Nullwerts angelegt. Sobald es einen relevanten Wert hatte, werden spätere Wechsel auf leer oder `0` normal gespeichert.

## Set-Befehle

Die angebotene Set-Liste richtet sich nach den erkannten Fähigkeiten der VIOLET-Konfiguration. Häufige Beispiele:

```text
set pool pump on 1800 2
set pool pumpSpeed 2 1800
set pool solar auto
set pool heater auto
set pool backwash on 120
set pool rinse on 30
set pool refill auto
set pool light on
set pool cover open
set pool pvSurplus on 2
```

Sollwerte:

```text
set pool targetPh 7.20
set pool targetOrp 750
set pool targetMinChlorine 0.30
set pool targetHeater 28.5
set pool targetSolar 30.5
```

Dosierung und Kanisterverwaltung:

```text
set pool dosageChlor start
set pool doseChlor 30
set pool doseStop Chlor
set pool canisterChlorAdjust 500
set pool canisterChlorReset 20000
```

Weitere Befehlsgruppen:

| Bereich | Befehle/Schema |
|---|---|
| Erweiterungsrelais | `ext1_1` bis `ext2_8` |
| DMX | `dmx1` bis `dmx12`, `dmxAll` |
| Digitaleingänge | `diRule1` bis `diRule7` |
| Kalibrierung | `calibrationRestorePh`, `calibrationRestoreOrp`, `calibrationRestoreChlor` |
| Systemdienste | `serviceFtp`, `serviceSamba`, `serviceSsh`, `serviceShairport`, `serviceHomebridge`, `serviceAlexa`, `serviceTunnel`, `serviceSupportTunnel` |
| Wartung | `resetBlocking`, `outputTest`, `reboot`, `firmwareUpdate` |
| Backup | `manualBackup`, `localRestore` |
| RS485 | `rs485Live`, `rs485Done` |
| System | `network`, `networkJson`, `timezone` |
| generischer Zugriff | `function`, `rawGet`, `rawPost` |

Die vollständige Syntax, zulässige Werte und Beispiele zeigt FHEMWEB kontextbezogen in der Commandref an.

> Befehle wie `firmwareUpdate`, `reboot`, `localRestore`, `network`, `networkJson`, `outputTest`, `rs485Live`, `rawGet` und `rawPost` greifen direkt in die Steuerung ein. Sie sollten nur verwendet werden, wenn Wirkung und Parameter bekannt sind.

## Get-Befehle

| Befehl | Beschreibung |
|---|---|
| `values [GROUP ...]` | liest automatisch erkannte oder explizit angegebene Reading-Gruppen |
| `valuesGroup GROUP` | liest genau eine Gruppe aus `ALL`, `DOSAGE`, `RUNTIMES`, `PUMPPRIOSTATE`, `BACKWASH`, `SYSTEM` |
| `outputs` | liest Ausgangszustände als `output...`-Readings |
| `config [KEY ...]` | liest die Konfiguration für Diagnose und Discovery |
| `configKey KEY` | liest genau einen Konfigurationsschlüssel |
| `services` | liest den Zustand der VIOLET-Systemdienste |
| `localBackups` | liest Metadaten lokaler Backups |
| `updateState` | liest den Firmware- und Updatezustand |
| `rs485Data PUMPMODEL` | liest RS485-Pumpendaten |
| `raw /path?query` | ruft einen beliebigen GET-Endpunkt auf, ohne den Body als Reading zu speichern |

Beispiele:

```text
get pool values
get pool valuesGroup DOSAGE
get pool outputs
get pool configKey HEATER_set_temp
get pool services
get pool updateState
```

## Readings

API-Namen werden in stabile `lowerCamelCase`-Namen übersetzt. Messwerte erhalten kurze fachliche Namen:

| VIOLET-API | FHEM-Reading |
|---|---|
| `pH_value` | `ph` |
| `pH_value_min` | `phMin` |
| `pH_value_max` | `phMax` |
| `ORP_value` | `orp` |
| `ORP_value_min` | `orpMin` |
| `ORP_value_max` | `orpMax` |
| `pot_value` | `chlor` |
| `pot_value_min` | `chlorMin` |
| `pot_value_max` | `chlorMax` |
| `DOSAGE_phminus_setpoint` | `phTarget` |
| `DOSAGE_chlorine_setpoint_orp` | `orpTarget` |
| `DOSAGE_chlorine_lowerval_cl` | `chlorMinTarget` |
| `HEATER_set_temp` | `heaterTarget` |
| `SOLAR_maxtemp` | `solarTarget` |

Dosierkanäle verwenden einheitliche Präfixe wie `dosageChlor...`, `dosageElectrolysis...`, `dosagePhminus...`, `dosagePhplus...` und `dosageFloc...`. Ausgangs- und Dienstzustände beginnen beispielsweise mit `output...` beziehungsweise `service...`.

Readings werden grundsätzlich nur aktualisiert, wenn sich der Wert geändert hat. `state` ist die Ausnahme: Es wird bei jeder HTTP-Antwort aktualisiert, sodass sein Zeitstempel als Heartbeat verwendet werden kann.

## HTTP-Push von VIOLET

VIOLET kann Änderungen an den vom Modul registrierten FHEMWEB-Endpunkt senden.

Ohne Token:

```text
http://FHEM-IP:8083/fhem/VIOLET?device=pool
```

Mit Token:

```text
attr pool token MeinGeheimerToken
```

```text
http://FHEM-IP:8083/fhem/VIOLET?device=pool&token=MeinGeheimerToken
```

Das Token muss in Attribut und Push-URL identisch sein. Gepushte VIOLET-Werte durchlaufen dasselbe Reading-Mapping wie gepollte Werte. Technische Push-Metadaten werden getrennt gespeichert, beispielsweise `pushAuthState` und `pushLast`.

Der Push-Endpunkt sollte nur aus einem vertrauenswürdigen Netz erreichbar sein. Ist FHEMWEB außerhalb des lokalen Netzes verfügbar, sollte der Zugriff zusätzlich auf Netzwerkebene geschützt werden.

## Logging

Das normale Geräteattribut `verbose` steuert das Logging. Ist es am VIOLET-Gerät nicht gesetzt, gilt der Wert von `global` (FHEM-Standard: `3`).

- `verbose 1` protokolliert nur kritische Fehler.
- `verbose 2` ergänzt Warnungen und Informationen.
- `verbose 3` zeigt den allgemeinen Funktionsablauf.
- `verbose 4` ergänzt bereinigte Funktionsparameter.
- `verbose 5` zeigt strukturierte HTTP-Requests und -Responses mit Headern und auf 8192 Zeichen begrenzten Body-Vorschauen.

Passwörter, `Authorization`-Header, Basic-/Bearer-Werte, Cookies, Token, API-Schlüssel, Client-Secrets und PSKs werden vor jeder Ausgabe maskiert. Das gilt auch für normale VIOLET-Logmeldungen außerhalb der HTTP-Diagnose.

## API-Kompatibilität

Spezialisierte Befehle orientieren sich an der dokumentierten VIOLET-API. Für neue oder noch nicht abgebildete Firmwarefunktionen stehen `get ... raw`, `set ... rawGet`, `set ... rawPost` und `set ... function` als Diagnose- und Übergangslösung zur Verfügung. Diese Schnittstellen nehmen keine fachliche Plausibilitätsprüfung des angefragten Endpunkts vor.
