# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;
use vars qw(%defs $FW_chash);

# HTTP-Transport, Polling, Callbacks und eingehende VIOLET-Pushes.
# Die Implementierung bleibt im Paket main, damit FHEM-Callbacks und Kernhelfer
# ohne Adapter- oder Namensänderungen verwendet werden können.

# Validiert einen authentifizierten HTTP-Aufruf und übergibt ihn nicht blockierend an FHEM.
sub VIOLET_Request {
	my ($hash, %o) = @_;
	my $name = $hash->{NAME};
	my $method = uc($o{method} || 'GET');

	# Stufe 3 zeigt den Netzwerkablauf, Stufe 4 ergänzt Routing-/Steuervariablen.
	VIOLET_LogCall($hash, 'VIOLET_Request',
		'method='.$method,
		'path='.($o{path} // '/'),
		'purpose='.($o{purpose} // ''),
		'refresh='.($o{refresh} ? 1 : 0),
		'parseReadings='.($o{parseReadings} ? 1 : 0),
		'returnBody='.($o{returnBody} ? 1 : 0),
		'parsePrefix='.($o{parsePrefix} // ''));

	# Deaktivierte Geräte erzeugen keinen HTTP-Verkehr.
	if (AttrVal($name,'disable',0)) {
		VIOLET_Log($hash, 2, 'request skipped: device is disabled');
		return 'device is disabled';
	}

	# Eine Konfigurationsänderung kann relevante Readings ändern. Vor der nächsten
	# automatischen Werteabfrage eine neue Erkennung erzwingen.
	if (($o{path} || '') eq '/setConfig') {
		$hash->{VIOLET_CONFIG_DISCOVERED_AT} = 0;
	}

	my $url = VIOLET_BaseUrl($hash).($o{path} || '/');
	my @headers;
	push @headers, 'Accept: application/json, text/plain, */*';

	my ($user, $pass, $kvErr) = VIOLET_CredentialsInfo($hash);

	# Bei fehlerhaftem KeyValueStore-Zugriff jeden Steuerungsaufruf ablehnen. Das
	# Modul fällt nie auf einen nicht authentifizierten Aufruf zurück.
	if (defined($kvErr) && $kvErr ne '') {
		VIOLET_Log($hash, 1, 'critical KeyValueStore read error: '.VIOLET_LogValue($kvErr));
		VIOLET_UpdateCredentialState($hash);
		return 'error while reading password: '.$kvErr;
	}

	# Jeden Steuerungsaufruf ablehnen, bis Benutzername und Passwort vorhanden sind.
	if ($user eq '' || $pass eq '') {
		VIOLET_Log($hash, 2, 'request skipped: credentials are incomplete');
		VIOLET_UpdateCredentialState($hash);
		return 'credentials are required; attr '.$name.' username <user> and set '.$name.' password <password>';
	}

	# Nach 401/403 alle weiteren Aufrufe bis zur Änderung der Zugangsdaten stoppen.
	# Das verhindert wiederholtes Polling mit fehlgeschlagener Anmeldung.
	if ($hash->{VIOLET_AUTH_REJECTED}) {
		VIOLET_Log($hash, 2, 'request skipped: previous authentication was rejected');
		VIOLET_UpdateCredentialState($hash);
		return 'authentication was rejected; update username/password before retrying';
	}

	# Jeder VIOLET-API-Aufruf verwendet HTTP-Basic-Authentifizierung.
	push @headers, 'Authorization: Basic '.encode_base64($user.':'.$pass, '');

	readingsBeginUpdate($hash);
	VIOLET_BulkUpdateReading($hash, 'authUser', $user, 0, 0);
	VIOLET_BulkUpdateReading($hash, 'authState', $hash->{VIOLET_AUTH_VALIDATED} ? 'accepted' : 'configured', 0, 0);
	readingsEndUpdate($hash, 1);
	# POST-Aufrufe benötigen einen Inhaltstyp; GET-Aufrufe haben keinen Body-Typ.
	if ($method eq 'POST') {
		push @headers, 'Content-Type: '.($o{contentType} || 'application/x-www-form-urlencoded');
	}

	# Antwortinhalte als rohe Bytes behalten. Ohne Zeichensatz nimmt HttpUtils im
	# FHEM-Unicode-Modus sonst UTF-8 an. VIOLET kann UTF-8 oder Windows-1252 liefern;
	# daher erkennt VIOLET_DecodeJsonResponse UTF-8 streng und fällt auf 1252 zurück.
	my $param = {
		url           => $url,
		timeout       => AttrVal($name, 'timeout', 10),
		forceEncoding => '',
		hash          => $hash,
		method        => $method,
		header        => join("\r\n", @headers),
		callback      => \&VIOLET_HttpCallback,
		violetPurpose       => $o{purpose} || $method.' '.$url,
		violetRefresh       => $o{refresh} || 0,
		violetParseReadings => $o{parseReadings} || 0,
		violetReturnBody    => $o{returnBody} || 0,
		violetAsyncClient   => $o{returnBody} ? $hash->{CL} : undef,
		violetParsePrefix   => $o{parsePrefix} || '',
		violetActiveFilter  => $o{activeFilter} || 0,
		violetAuthUsed      => 1,
	};
	$param->{data} = $o{data} if defined $o{data};

	VIOLET_LogHttpRequest($hash, $param);

	readingsBeginUpdate($hash);
	# lastRequest bei identischen periodischen Vorgängen ruhig halten. connection
	# nur aus dem endgültigen HTTP-Ergebnis aktualisieren, damit Polling nicht in
	# jedem Zyklus connected -> requesting -> connected erzeugt.
	VIOLET_BulkUpdateReading($hash, 'lastRequest', $param->{violetPurpose}, 0, 0);
	readingsEndUpdate($hash, 1);
	HttpUtils_NonblockingGet($param);
	return undef;
}

# Eine ausdrückliche Get-Antwort für die direkte Client-Ausgabe formatieren. JSON
# mit derselben Zeichensatzbehandlung dekodieren und lesbar/kanonisch ausgeben;
# Nicht-JSON-Inhalte als Text zurückgeben.
sub VIOLET_FormatGetOutput {
	my ($body) = @_;
	return '' if !defined($body);

	my ($obj, $jsonErr) = VIOLET_DecodeJsonResponse($body);

	# Strukturierte JSON-Antworten für eine reproduzierbare Client-Ausgabe kanonisieren.
	if (!defined($jsonErr) && ref($obj)) {
		return JSON::PP->new->utf8(0)->canonical(1)->pretty(1)->encode($obj);
	}

	# Nicht-JSON-Diagnosen erhalten, ohne rohe undekodierte Bytefolgen auszugeben.
	return $body if utf8::is_utf8($body);
	my $utf8 = eval { decode('UTF-8', $body, FB_CROAK) };
	return $utf8 if !$@;
	return decode('Windows-1252', $body);
}

# Ein asynchrones Get-Ergebnis an den auslösenden Client senden. GetFn stellt ihn
# als $hash->{CL} bereit; vor dem HTTP-Callback festhalten.
sub VIOLET_AsyncGetOutput {
	my ($param, $text) = @_;
	return if !$param->{violetReturnBody};
	my $cl = $param->{violetAsyncClient};
	return if !$cl;
	asyncOutput($cl, defined($text) ? $text : '');
}

# Verarbeitet Transportfehler, HTTP-Status und fachliche Antworttypen eines API-Aufrufs.
sub VIOLET_HttpCallback($$$) {
	my ($param, $err, $body) = @_;
	my $hash = $param->{hash};
	return if !$hash || !$hash->{NAME};

	my $code = $param->{code} // 0;
	VIOLET_LogCall($hash, 'VIOLET_HttpCallback',
		'purpose='.($param->{violetPurpose} // ''),
		'code='.$code,
		'error='.($err ne '' ? $err : '<none>'),
		'bodyLength='.length($body // ''));

	VIOLET_LogHttpResponse($hash, $param, $err, $body);

	# Transportfehler haben keine verlässliche HTTP-Antwort. connection/state als
	# Fehler markieren und den Fehlertext zur Diagnose behalten.
	if ($err ne '') {
		VIOLET_Log($hash, 1, 'critical transport error: '.VIOLET_LogValue($err));
		# Fehlgeschlagene Erkennung darf die automatische Polling-Kette nicht sperren.
		if (($param->{violetPurpose} || '') eq 'discoverConfig') {
			delete $hash->{VIOLET_CONFIG_DISCOVERY_PENDING};
			delete $hash->{VIOLET_PENDING_VALUES_PURPOSE};
		} elsif (($param->{violetPurpose} || '') eq 'discoverHardware') {
			delete $hash->{VIOLET_HARDWARE_DISCOVERY_PENDING};
			delete $hash->{VIOLET_PENDING_VALUES_PURPOSE};
		}
		readingsBeginUpdate($hash);
		VIOLET_BulkUpdateReading($hash, 'connection', 'error', 0, 0);
		VIOLET_BulkUpdateReading($hash, 'lastError', $err, 0, 0);
		VIOLET_BulkUpdateReading($hash, 'state', 'error', 1, 0);
		readingsEndUpdate($hash, 1);
		VIOLET_AsyncGetOutput($param, 'ERROR: '.$err);
		return;
	}

	my $purpose = $param->{violetPurpose} || '';

	# 401/403 verwirft die Anmeldung und stoppt den Poll-Timer. Bis zur Änderung von
	# Benutzername oder Passwort und Löschen des Merkmals folgt kein weiterer Aufruf.
	if ($code == 401 || $code == 403) {
		VIOLET_Log($hash, 2, 'authentication rejected by controller: HTTP '.$code);
		$hash->{VIOLET_AUTH_REJECTED} = 1;
		delete $hash->{VIOLET_AUTH_VALIDATED};
		delete $hash->{VIOLET_CONFIG_DISCOVERY_PENDING};
		delete $hash->{VIOLET_HARDWARE_DISCOVERY_PENDING};
		delete $hash->{VIOLET_PENDING_VALUES_PURPOSE};
		RemoveInternalTimer($hash);

		readingsBeginUpdate($hash);
		VIOLET_BulkUpdateReading($hash, 'connection', 'http_'.$code, 0, 0);
		VIOLET_BulkUpdateReading($hash, 'lastHttpCode', $code, 0, 0);
		VIOLET_BulkUpdateReading($hash, 'authState', 'rejected', 0, 0);
		VIOLET_BulkUpdateReading($hash, 'state', 'http_'.$code, 1, 0);
		readingsEndUpdate($hash, 1);
		VIOLET_AsyncGetOutput($param, 'ERROR: HTTP '.$code);
		return;
	}

	# Fehlgeschlagene HTTP-Antworten für normale FHEM-Logstufen einordnen.
	if ($code >= 500) {
		VIOLET_Log($hash, 1, 'critical controller HTTP error '.$code.' for '.$purpose);
	} elsif ($code < 200 || $code >= 300) {
		VIOLET_Log($hash, 2, 'controller returned HTTP '.$code.' for '.$purpose);
	}

	# Jede erfolgreiche Antwort wurde mit Basic Auth angefordert. Aktuelle
	# Zugangsdaten bestätigen; state bleibt der in jedem Zyklus aktualisierte Herzschlag.
	if ($code >= 200 && $code < 300) {
		$hash->{VIOLET_AUTH_VALIDATED} = 1;
		delete $hash->{VIOLET_AUTH_REJECTED};
	}

	readingsBeginUpdate($hash);
	VIOLET_BulkUpdateReading($hash, 'connection', ($code >= 200 && $code < 300) ? 'connected' : 'http_'.$code, 0, 0);
	VIOLET_BulkUpdateReading($hash, 'lastHttpCode', $code, 0, 0);
	VIOLET_BulkUpdateReading($hash, 'state', ($code >= 200 && $code < 300) ? 'connected' : 'http_'.$code, 1, 0);
	VIOLET_BulkUpdateReading($hash, 'authState', ($code >= 200 && $code < 300) ? 'accepted' : 'configured', 0, 0);
	readingsEndUpdate($hash, 1);

	# Erfolgreiche Erkennung intern zwischenspeichern und sofort die auslösende
	# Werteabfrage anschließen. Konfigurationsdetails werden dabei nicht als
	# config*-Readings dupliziert.
	if ($code >= 200 && $code < 300 && $purpose eq 'discoverConfig') {
		delete $hash->{VIOLET_CONFIG_DISCOVERY_PENDING};
		my $ok = VIOLET_ApplyConfigDiscovery($hash, $body);
		my $nextPurpose = delete($hash->{VIOLET_PENDING_VALUES_PURPOSE}) || 'poll';

		# Unerwartetes Konfigurations-JSON fällt auf die breite Abfrage zurück, damit
		# das Gerät nutzbar bleibt; ein späterer Poll versucht die Erkennung erneut.
		if (!$ok) {
			VIOLET_Log($hash, 2, 'config discovery failed; broad readings query will be used');
			my $query = VIOLET_BroadReadingsQuery();
			$query =~ s/,/, /g;
			$hash->{VIOLET_AUTO_QUERY} = $query;
			$hash->{VIOLET_CONFIG_DISCOVERED_AT} = 0;
			delete $hash->{VIOLET_ACTIVE_PREFIXES};
		}
		# Hardwareanwesenheit aus einer ungefilterten ALL-Antwort erkennen, physische
		# Module aber nur mit SYSTEM_*module_alive_count akzeptieren. Rohe EXT*-
		# Platzhalter bewusst nicht als Nachweis verwenden.
		if ($ok) {
			$hash->{VIOLET_PENDING_VALUES_PURPOSE} = $nextPurpose;
			$hash->{VIOLET_HARDWARE_DISCOVERY_PENDING} = 1;
			VIOLET_Log($hash, 2, 'config discovery completed; checking hardware profile');
			VIOLET_Request($hash, method=>'GET', path=>'/getReadings?ALL',
				purpose=>'discoverHardware', refresh=>0);
			return;
		}

		my $query = VIOLET_EffectiveReadingsQuery($hash) || VIOLET_BroadReadingsQuery();
		VIOLET_Request($hash, method=>'GET', path=>'/getReadings?'.$query,
			purpose=>$nextPurpose, parseReadings=>1, activeFilter=>0, refresh=>0);
		return;
	}

	# Die Hardwareprüfung erzeugt bewusst keine Readings. Sie aktualisiert nur das
	# interne Fähigkeitsprofil und startet danach die optimierte Werteabfrage.
	if ($purpose eq 'discoverHardware') {
		delete $hash->{VIOLET_HARDWARE_DISCOVERY_PENDING};
		my $nextPurpose = delete($hash->{VIOLET_PENDING_VALUES_PURPOSE}) || 'poll';

		# Nur erfolgreiche Hardwareantworten dürfen das interne Fähigkeitsprofil verändern.
		if ($code >= 200 && $code < 300) {
			my $ok = VIOLET_ApplyHardwareDiscovery($hash, $body);
			VIOLET_Log($hash, 2, $ok
				? 'hardware discovery completed; optimized readings query active'
				: 'hardware discovery failed; extension commands remain hidden');
		} else {
			VIOLET_Log($hash, 2, 'hardware discovery HTTP '.$code.'; extension commands remain hidden');
		}

		my $query = VIOLET_EffectiveReadingsQuery($hash) || VIOLET_BroadReadingsQuery();
		VIOLET_Request($hash, method=>'GET', path=>'/getReadings?'.$query,
			purpose=>$nextPurpose, parseReadings=>1, activeFilter=>1, refresh=>0);
		return;
	}

	# Fehlgeschlagene Erkennung ist nicht fatal. Sperre lösen und beim nächsten Poll
	# erneut versuchen, statt die Fehlerantwort in Steuerungs-Readings zu schreiben.
	if ($purpose eq 'discoverConfig' && !($code >= 200 && $code < 300)) {
		delete $hash->{VIOLET_CONFIG_DISCOVERY_PENDING};
		delete $hash->{VIOLET_PENDING_VALUES_PURPOSE};
		return;
	}

	# Ausdrückliche Get-Ausgabe direkt zurückgeben und nie in Readings umwandeln.
	# Andere erfolgreiche Aufrufe behalten ihre normale Reading-Auswertung.
	if ($param->{violetReturnBody}) {
		my $out = ($code >= 200 && $code < 300)
			? VIOLET_FormatGetOutput($body)
			: 'ERROR: HTTP '.$code.(defined($body) && $body ne '' ? "\n".VIOLET_FormatGetOutput($body) : '');
		VIOLET_AsyncGetOutput($param, $out);
	} elsif ($code >= 200 && $code < 300) {

		# Erfolgreiche Antworten abhängig vom Request entweder allgemein oder präfixiert lesen.
		if ($param->{violetParseReadings}) {
			VIOLET_ParseJsonToReadings($hash, $body, '', $param->{violetActiveFilter});
		} elsif ($param->{violetParsePrefix}) {
			VIOLET_ParseJsonToReadings($hash, $body, $param->{violetParsePrefix}, 0);
		}
	}

	# Schreibvorgängen folgt eine konfigurationsbewusste Momentaufnahme. Ein
	# vorheriges /setConfig hat den Erkennungszeitstempel bereits verworfen.
	if ($param->{violetRefresh} && $code >= 200 && $code < 300) {
		VIOLET_RequestAutoValues($hash, 'refreshAfterSet');
	}
}

# Fragt zyklisch die aktiven Steuerungswerte ab und plant danach den nächsten Lauf.
# Normale Readings werden nur bei Änderung aktualisiert; state dient mit jedem
# neuen Zeitstempel als Watchdog-Herzschlag.
sub VIOLET_Poll($) {
	my ($hash) = @_;
	VIOLET_LogCall($hash, 'VIOLET_Poll');
	return if !$hash || !$hash->{NAME};
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash);

	# Nie ohne vollständige Zugangsdaten pollen und nach Ablehnung der aktuellen
	# Anmeldung durch die Steuerung kein Polling fortsetzen.
	if (!VIOLET_CredentialsReady($hash)) {
		VIOLET_UpdateCredentialState($hash);
		return;
	}

	# Polling bei Deaktivierung überspringen, sonst die konfigurationsbewusste Abfrage
	# oder ein ausdrücklich konfiguriertes readingsQuery verwenden.
	if (!AttrVal($name,'disable',0)) {
		VIOLET_RequestAutoValues($hash, 'poll');
	}

	# Nächsten Zyklus nur mit weiterhin gültigen Zugangsdaten planen. Ein 401/403-
	# Callback entfernt den Timer wieder und blockiert weitere Zyklen.
	VIOLET_SchedulePoll($hash);
}

# Plant genau einen Poll-Timer unter Beachtung von disable, Intervall und Zugangsdaten.
sub VIOLET_SchedulePoll {
	my ($hash, $delay, $userOverride) = @_;
	return if !$hash || !$hash->{NAME};
	my $name = $hash->{NAME};
	return if AttrVal($name,'disable',0);

	# Keinen InternalTimer anlegen, bevor Benutzername/Passwort vollständig sind.
	# userOverride gilt nur während AttrFn eine Benutzernamenänderung verarbeitet,
	# weil AttrVal() bis zur Rückkehr von AttrFn noch den alten Wert enthält.
	return if !VIOLET_CredentialsReady($hash, $userOverride);

	my $interval = AttrVal($name, 'interval', 60);
	return if !$interval;
	$delay = $interval if !defined $delay;
	InternalTimer(gettimeofday() + $delay, 'VIOLET_Poll', $hash, 0);
}

# Baut die Basis-URL aus Host sowie den wirksamen SSL- und Portattributen.
sub VIOLET_BaseUrl {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $ssl = AttrVal($name, 'useSSL', 0) ? 'https' : 'http';
	my $port = AttrVal($name, 'port', '');
	my $host = $hash->{HOST};
	return $ssl.'://'.$host.($port ne '' ? ':'.$port : '');
}

# HTTP-Push-Empfänger. FHEMWEB übergibt die URI an FWEXT-Funktionen. VIOLET-
# Meldungen wie ERRORCODE=0020&SUBJECT=... werden zu errorCode/errorText/errorType/
# errorSeverity/errorInfo normalisiert; weitere Paare nutzen die übliche Zuordnung.
# FWEXT-HTTP-Antwort direkt senden. FHEMWEB erlaubt nach eigenem HTTP-Header undef
# als FW_RETTYPE. Das garantiert Content-Length unabhängig von WEB-httpHeader.
sub VIOLET_PushResponse {
	my ($hashOrName, $ok) = @_;
	my $body = $ok ? 'OK' : 'ERROR';

	# Das VIOLET-Push-Protokoll braucht nur eine kurze synchrone Textantwort. OK hat
	# Länge 2, ERROR Länge 5; beide sind ASCII und damit bytesicher.
	my $response =
			"HTTP/1.1 200 OK\r\n"
		. "Content-Type: text/plain; charset=utf-8\r\n"
		. "Content-Length: ".length($body)."\r\n"
		. "Cache-Control: no-cache, no-store, must-revalidate\r\n"
		. "Connection: close\r\n"
		. "\r\n"
		. $body;

	VIOLET_Log($hashOrName, 5, 'push HTTP response body='.$body.
		' contentLength='.length($body));

	# Ein FWEXT-Callback läuft in FHEMWEB; der aktive Client-Hash steht daher als
	# $FW_chash bereit. Vollständige Antwort vor der Rückgabe von undef schreiben.
	if ($FW_chash) {
		main::TcpServer_WriteBlocking($FW_chash, $response);
		return (undef, undef);
	}

	# Defensiver Rückfall für direkte Unit-Tests oder ungewöhnliche Aufrufer außerhalb
	# von FHEMWEB. Normaler FHEMWEB-Betrieb nutzt stets den oberen Zweig.
	return ('text/plain; charset=utf-8', $body);
}

# HTTP-Push-Empfänger. Jeder Aufruf erhält genau OK, wenn mindestens ein Nutzwert
# angenommen und verarbeitet wurde, andernfalls genau ERROR.
sub VIOLET_Push($) {
	my ($arg) = @_;
	my $query = $arg // '';
	$query =~ s/^.*?\?//;
	my %p = VIOLET_ParseQuery($query);
	my $name = delete $p{device} // delete $p{DEVICE} // '';

	# Push-Ablauf protokollieren, ohne je einen Tokenwert offenzulegen.
	VIOLET_LogCall($name || 'VIOLET', 'VIOLET_Push', 'device='.($name || '<missing>'));
	my %debugPush = %p;
	$debugPush{token} = '<redacted>' if exists $debugPush{token};
	$debugPush{TOKEN} = '<redacted>' if exists $debugPush{TOKEN};
	VIOLET_Log($name || 'VIOLET', 4, 'push keys='.join(',', sort keys %debugPush));
	VIOLET_Log($name || 'VIOLET', 5, 'push payload='.
		join('&', map { $_.'='.VIOLET_LogValue($debugPush{$_}) } sort keys %debugPush));

	# Fehlende/unbekannte Zielgeräte ablehnen. Der Antwortinhalt verrät bewusst keine
	# Interna, weil VIOLET nur OK oder ERROR benötigt.
	if ($name eq '' || !exists $defs{$name} || ($defs{$name}{TYPE} // '') ne 'VIOLET') {
		VIOLET_Log($name || 'VIOLET', 2, 'push rejected: missing or unknown device parameter');
		return VIOLET_PushResponse($name || 'VIOLET', 0);
	}

	my $hash = $defs{$name};
	my $expectedToken = AttrVal($name, 'token', '');
	my $givenToken = exists($p{token}) ? delete($p{token}) :
										(exists($p{TOKEN}) ? delete($p{TOKEN}) : '');

	# Tokenprüfung ist optional; ein konfiguriertes Token muss exakt übereinstimmen.
	if ($expectedToken ne '' && $givenToken ne $expectedToken) {
		VIOLET_Log($hash, 2, 'incoming push rejected because token does not match');
		VIOLET_SingleUpdateReading($hash, 'pushAuthState', 'rejected', 0, 0);
		return VIOLET_PushResponse($hash, 0);
	}

	# Ein Aufruf nur mit device/token enthält nichts Verarbeitbares und ist daher
	# keine erfolgreiche Push-Meldung.
	if (!keys %p) {
		VIOLET_Log($hash, 2, 'push rejected: no payload values supplied');
		return VIOLET_PushResponse($hash, 0);
	}

	my $updateOpen = 0;
	my $processed = 0;
	my $processingOk = eval {
		readingsBeginUpdate($hash);
		$updateOpen = 1;

		VIOLET_BulkUpdateReading(
			$hash, 'pushAuthState',
			$expectedToken ne '' ? 'accepted' : 'not_required',
			0, 0
		);

		# ERRORCODE/SUBJECT bilden eine logische Steuerungsmeldung. Rohcode samt
		# führender Nullen behalten, Metadaten übersetzen und SUBJECT als errorInfo
		# statt als subject-Reading veröffentlichen.
		my $rawErrorCode =
			exists($p{ERRORCODE}) ? delete($p{ERRORCODE}) :
			(exists($p{errorcode}) ? delete($p{errorcode}) : undef);
		my $errorInfo =
			exists($p{SUBJECT}) ? delete($p{SUBJECT}) :
			(exists($p{subject}) ? delete($p{subject}) : undef);

		# Nur tatsächlich übertragene Fehlercodes in die normalisierten Metadaten zerlegen.
		if (defined($rawErrorCode)) {
			my ($errorType, $errorSeverity, $errorText) =
				VIOLET_ErrorMetadata($rawErrorCode);

			VIOLET_BulkUpdateReading($hash, 'errorCode',     $rawErrorCode,   0, 0);
			VIOLET_BulkUpdateReading($hash, 'errorText',     $errorText,      0, 0);
			VIOLET_BulkUpdateReading($hash, 'errorType',     $errorType,      0, 0);
			VIOLET_BulkUpdateReading($hash, 'errorSeverity', $errorSeverity,  0, 0);
			$processed++;
		}

		# SUBJECT ist Kontext der Steuerung und kann genauer als die statische
		# Codebeschreibung sein. Einmal als errorInfo speichern.
		if (defined($errorInfo) && $errorInfo ne '') {
			VIOLET_BulkUpdateReading($hash, 'errorInfo', $errorInfo, 0, 0);
			$processed++;
		}

		# Weitere Push-Felder mit derselben kanonischen Zuordnung wie Get-Werte
		# speichern. ERRORCODE und SUBJECT wurden zur Vermeidung von Duplikaten entfernt.
		for my $k (sort keys %p) {
			my $reading = VIOLET_PrefixedReading('', $k);
			VIOLET_BulkUpdateReading($hash, $reading, $p{$k}, 0, 1);
			$processed++;
		}

		VIOLET_BulkUpdateReading($hash, 'pushLast', scalar localtime(), 0, 0);
		readingsEndUpdate($hash, 1);
		$updateOpen = 0;
		1;
	};

	# Unerwartete FHEM-/Reading-Fehler in die Protokollantwort ERROR umwandeln und
	# den Grund in Log3 behalten, statt ihn nach außen offenzulegen.
	if (!$processingOk || !$processed) {
		my $error = $@ || 'no payload value processed';
		eval { readingsEndUpdate($hash, 0) } if $updateOpen;
		VIOLET_Log($hash, 1, 'critical push processing error: '.VIOLET_LogValue($error));
		return VIOLET_PushResponse($hash, 0);
	}

	VIOLET_Log($hash, 2, 'push accepted and processed');
	return VIOLET_PushResponse($hash, 1);
}

1;
