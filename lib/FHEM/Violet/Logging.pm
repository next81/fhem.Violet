# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

package main;

use strict;
use warnings;

# Gemeinsames abgestuftes Logging für alle VIOLET-Komponenten. Das normale
# Device-Attribut verbose hat Vorrang; ohne lokalen Wert gilt global.verbose.
sub VIOLET_LogEnabled {
	my ($hashOrName, $level) = @_;
	return 0 if !defined($level) || $level !~ /^[1-5]$/;

	my $name = ref($hashOrName) eq 'HASH'
		? ($hashOrName->{NAME} // 'VIOLET')
		: ($hashOrName // 'VIOLET');
	my $verbose = AttrVal($name, 'verbose', AttrVal('global', 'verbose', 3));
	$verbose = 3 if !defined($verbose) || $verbose !~ /^\d+$/;
	return $verbose >= $level ? 1 : 0;
}

# Sensible Queryparameter maskieren, ohne Pfad und Parameternamen zu verlieren.
sub VIOLET_LogSafeUrl {
	my ($url) = @_;
	my $safe = defined($url) ? "$url" : '';
	$safe =~ s{([?&#](?:password|passwd|pass|token|access_token|refresh_token|auth_token|api_key|apikey|secret|client_secret|psk|key)=)[^&#\s]*}{$1<masked>}gi;
	return $safe;
}

# Authentifizierungs-, Cookie- und Tokenheader vollständig maskieren.
sub VIOLET_LogSafeHeader {
	my ($header) = @_;
	my $safe = defined($header) ? "$header" : '';
	$safe =~ s/^(Authorization:\s*).*$/$1<masked>/gmi;
	$safe =~ s/^(Cookie:\s*).*$/$1<masked>/gmi;
	$safe =~ s/^(Set-Cookie:\s*[^=;\s]+=)[^;\r\n]*/$1<masked>/gmi;
	$safe =~ s/^((?:X-[A-Za-z0-9-]*(?:Token|Api-Key)|AuthenticationToken):\s*).*$/$1<masked>/gmi;
	return VIOLET_LogSafeUrl($safe);
}

# Geheimnisse in Formular-, JSON-, XML- und freier Schlüssel/Wert-Schreibweise
# entfernen. Basic-/Bearer-Werte werden unabhängig vom umgebenden Format maskiert.
sub VIOLET_LogSafeBody {
	my ($body) = @_;
	return '' if !defined($body);
	my $safe = "$body";
	my $secret = qr/(?:password|passwd|pass|token|access_token|refresh_token|auth_token|api_key|apikey|secret|client_secret|psk|key)/i;

	$safe =~ s/((?:^|&)[^&=]*$secret[^&=]*=)[^&]*/$1<masked>/gi;
	$safe =~ s/("[^"\r\n]*$secret[^"\r\n]*"\s*:\s*")[^"]*/$1<masked>/gi;
	$safe =~ s/(<[^>\r\n]*$secret[^>\r\n]*>).*?(<\/[^>]+>)/$1<masked>$2/gis;
	$safe =~ s/\b((?:Basic|Bearer)\s+)[^\s,;]+/$1<masked>/gi;
	$safe =~ s/\b($secret\s*[=:]\s*)["']?[^\s"',;&]+/$1<masked>/gi;
	return VIOLET_LogSafeUrl($safe);
}

# Große Diagnosewerte begrenzen, damit verbose 5 das FHEM-Log nicht unkontrolliert
# wachsen lässt. Die ursprüngliche Zeichenzahl bleibt im Kürzungshinweis sichtbar.
sub VIOLET_LogTruncate {
	my ($text, $limit) = @_;
	$text = '' if !defined($text);
	$limit = 8192 if !defined($limit) || $limit !~ /^\d+$/ || $limit < 256;
	return $text if length($text) <= $limit;
	return substr($text, 0, $limit)
		."\n... <gekürzt; ".length($text).' Zeichen insgesamt>';
}

# Eine bereits bereinigte Meldung mit dem von FHEM erwarteten Device-Präfix
# schreiben. Die erneute zentrale Bereinigung schützt auch normale Logaufrufe.
sub VIOLET_Log {
	my ($hashOrName, $level, $message) = @_;
	return if !VIOLET_LogEnabled($hashOrName, $level);
	my $name = ref($hashOrName) eq 'HASH'
		? ($hashOrName->{NAME} // 'VIOLET')
		: ($hashOrName // 'VIOLET');
	my $safe = VIOLET_LogSafeHeader(VIOLET_LogSafeBody($message // ''));
	$safe = VIOLET_LogTruncate($safe, 16384);
	Log3($name, $level, 'VIOLET '.$name.': '.$safe);
	return;
}

# Stufe 3 zeigt den Funktionsfluss, Stufe 4 zusätzlich bereinigte Parameter.
sub VIOLET_LogCall {
	my ($hashOrName, $function, @args) = @_;
	VIOLET_Log($hashOrName, 3, 'call '.($function // 'Function'));
	return if !@args || !VIOLET_LogEnabled($hashOrName, 4);
	VIOLET_Log($hashOrName, 4, ($function // 'Function').' args=['.
		join(', ', map { VIOLET_LogValue($_) } @args).']');
	return;
}

# Vollständige HTTP-Metadaten und eine begrenzte, bereinigte Body-Vorschau für
# verbose 5 protokollieren.
sub VIOLET_LogHttpRequest {
	my ($hash, $param) = @_;
	return if !VIOLET_LogEnabled($hash, 5);
	my $header = VIOLET_LogTruncate(VIOLET_LogSafeHeader($param->{header} // ''), 8192);
	my $body = VIOLET_LogTruncate(VIOLET_LogSafeBody($param->{data}), 8192);
	VIOLET_Log($hash, 5,
		"HTTP REQUEST\n"
		.'purpose='.($param->{violetPurpose} // '')."\n"
		.'method='.($param->{method} // 'GET')."\n"
		.'url='.VIOLET_LogSafeUrl($param->{url} // '')."\n"
		."headers:\n".$header."\n"
		.'body-preview ('.length($param->{data} // '')." bytes):\n".$body
	);
	return;
}

# HTTP-Antworten einschließlich Status, Fehler, Header und Body-Vorschau auf
# verbose 5 ausgeben; Geheimnisse werden vor der Protokollierung entfernt.
sub VIOLET_LogHttpResponse {
	my ($hash, $param, $err, $body) = @_;
	return if !VIOLET_LogEnabled($hash, 5);
	my $header = VIOLET_LogTruncate(VIOLET_LogSafeHeader($param->{httpheader} // ''), 8192);
	my $safeBody = VIOLET_LogTruncate(VIOLET_LogSafeBody($body), 8192);
	VIOLET_Log($hash, 5,
		"HTTP RESPONSE\n"
		.'purpose='.($param->{violetPurpose} // '')."\n"
		.'code='.($param->{code} // 0)."\n"
		.'url='.VIOLET_LogSafeUrl($param->{url} // '')."\n"
		.'error='.VIOLET_LogSafeBody($err // '')."\n"
		."headers:\n".$header."\n"
		.'body-preview ('.length($body // '')." bytes):\n".$safeBody
	);
	return;
}

1;
