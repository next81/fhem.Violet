# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

use strict;
use warnings;

BEGIN {
	package HttpUtils;

	sub import { }

	$INC{'HttpUtils.pm'} = __FILE__;
}

package main;

use Encode qw(encode);
use Test2::V0;
use lib 'lib';

our (
	%defs,
	%attr,
	%data,
	$readingFnAttributes,
	$unicodeEncoding,
	$FW_chash,
);

our (
	@asyncOutputCalls,
	@httpCalls,
	@logCalls,
	@readingCalls,
	@readingFlow,
	@removedTimers,
	@tcpWrites,
	@timers,
	%keyValues,
	$keyValueReadError,
	$keyValueWriteError,
	$readingBulkError,
);

sub AttrVal {
	my ($name, $attribute, $default) = @_;
	return exists($attr{$name}) && exists($attr{$name}{$attribute})
		? $attr{$name}{$attribute}
		: $default;
}

sub getKeyValue {
	my ($key) = @_;
	return ($keyValueReadError, $keyValues{$key});
}

sub setKeyValue {
	my ($key, $value) = @_;
	$keyValues{$key} = $value;
	return ($keyValueWriteError);
}

sub Log3 {
	push @logCalls, [@_];
}

sub readingsBeginUpdate {
	push @readingFlow, ['begin', $_[0]];
}

sub readingsEndUpdate {
	push @readingFlow, ['end', @_];
}

sub readingsBulkUpdate {
	my ($hash, $reading, $value) = @_;
	# Ein gezielt gesetzter Testfehler prueft die defensive Push-Fehlerbehandlung.
	die $readingBulkError if defined($readingBulkError);
	$hash->{READINGS}{$reading}{VAL} = $value;
	push @readingCalls, ['bulk', $reading, $value];
}

sub readingsSingleUpdate {
	my ($hash, $reading, $value, $trigger) = @_;
	$hash->{READINGS}{$reading}{VAL} = $value;
	push @readingCalls, ['single', $reading, $value, $trigger];
}

sub RemoveInternalTimer {
	push @removedTimers, $_[0];
}

sub InternalTimer {
	push @timers, [@_];
}

sub HttpUtils_NonblockingGet {
	push @httpCalls, $_[0];
}

sub asyncOutput {
	push @asyncOutputCalls, [@_];
}

sub deviceEvents {
	my ($device) = @_;
	return $device->{EVENTS};
}

sub TcpServer_WriteBlocking {
	push @tcpWrites, [@_];
}

my $loaded = do './FHEM/50_Violet.pm';
die $@ if $@;
die $! if !defined($loaded);
ok($loaded, 'VIOLET module loads in the isolated FHEM context');

sub resetContext {
	%defs = ();
	%attr = ();
	%data = ();
	%keyValues = ();
	@asyncOutputCalls = ();
	@httpCalls = ();
	@logCalls = ();
	@readingCalls = ();
	@readingFlow = ();
	@removedTimers = ();
	@tcpWrites = ();
	@timers = ();
	$keyValueReadError = undef;
	$keyValueWriteError = undef;
	$readingBulkError = undef;
	$readingFnAttributes = '';
	$unicodeEncoding = 1;
	$FW_chash = undef;
}

sub newDevice {
	my (%overrides) = @_;
	my $hash = {
		NAME => 'pool',
		TYPE => 'VIOLET',
		HOST => 'violet.local',
		READINGS => {},
		helper => {},
		%overrides,
	};
	$defs{$hash->{NAME}} = $hash;
	return $hash;
}

sub configureCredentials {
	my ($hash) = @_;
	$attr{$hash->{NAME}}{username} = 'admin';
	$keyValues{'VIOLET_PASSWORD_'.$hash->{NAME}} = 'secret';
}

sub lastHttpCall {
	return $httpCalls[-1];
}

subtest 'metadata and logging' => sub {
	resetContext();
	my $hash = newDevice();

	my @known = VIOLET_ErrorMetadata('0020');
	is($known[0], 'ALERT', 'known controller error type is resolved');
	is($known[1], 'critical', 'known controller severity is resolved');

	my @range = VIOLET_ErrorMetadata('81');
	is($range[0], 'WARNING', 'documented error range is resolved');
	like($range[2], qr/1/, 'error range text contains its derived program number');

	my @unknown = VIOLET_ErrorMetadata('invalid');
	is($unknown[0], 'UNKNOWN', 'invalid error code has unknown metadata');
	my @programWarning = VIOLET_ErrorMetadata('95');
	is($programWarning[0], 'WARNING', 'second documented warning range is resolved');
	like($programWarning[2], qr/5/, 'second warning range derives its program number');
	my @outputWarning = VIOLET_ErrorMetadata('105');
	is($outputWarning[0], 'WARNING', 'output warning range is resolved');
	like($outputWarning[2], qr/5/, 'output warning range derives its output number');
	my @unknownNumeric = VIOLET_ErrorMetadata('999');
	is($unknownNumeric[0], 'UNKNOWN', 'unknown numeric code has unknown metadata');

	$attr{global}{verbose} = 2;
	ok(VIOLET_LogEnabled($hash, 2), 'global verbose is used without a device value');
	ok(!VIOLET_LogEnabled($hash, 3), 'global verbose suppresses more detailed messages');

	$attr{pool}{verbose} = 1;
	ok(!VIOLET_LogEnabled($hash, 2), 'device verbose takes precedence over global verbose');
	my $logCount = scalar(@logCalls);
	VIOLET_Log($hash, 2, 'suppressed message');
	is(scalar(@logCalls), $logCount, 'messages above device verbose are not written');

	$attr{pool}{verbose} = 4;
	VIOLET_Log($hash, 2, 'message');
	is($logCalls[-1], ['pool', 2, 'VIOLET pool: message'], 'device log prefix is stable');

	VIOLET_LogCall($hash, 'Example', "line\nbreak");
	is($logCalls[-2][1], 3, 'function call logs its flow level');
	like($logCalls[-1][2], qr/line\\nbreak/, 'function arguments are escaped');

	my $safeUrl = VIOLET_LogSafeUrl('http://violet.local/api?token=url-secret&value=1');
	unlike($safeUrl, qr/url-secret/, 'URL secrets are masked');
	like($safeUrl, qr/token=<masked>/, 'masked URL keeps the parameter name');

	my $safeHeader = VIOLET_LogSafeHeader(
		"Authorization: Basic auth-secret\r\nCookie: sid=cookie-secret\r\nX-Api-Key: key-secret"
	);
	unlike($safeHeader, qr/(?:auth-secret|cookie-secret|key-secret)/, 'sensitive HTTP headers are masked');

	my $safeBody = VIOLET_LogSafeBody(
		'{"password":"password-secret","token":"token-secret","value":1}'
	);
	unlike($safeBody, qr/(?:password-secret|token-secret)/, 'secrets in request bodies are masked');

	my $truncated = VIOLET_LogTruncate('x' x 300, 256);
	like($truncated, qr/Zeichen insgesamt/, 'long log values receive a truncation marker');
	ok(length($truncated) < 300, 'long log values are shortened');

	$attr{pool}{verbose} = 5;
	my $param = {
		url           => 'http://violet.local/api?token=url-secret',
		method        => 'POST',
		header        => "Authorization: Bearer auth-secret\r\nX-Api-Key: key-secret",
		data          => 'password=body-secret&value=1',
		violetPurpose => 'loggingTest',
		code          => 200,
		httpheader    => "Set-Cookie: sid=cookie-secret\r\nContent-Type: application/json",
	};
	VIOLET_LogHttpRequest($hash, $param);
	VIOLET_LogHttpResponse(
		$hash,
		$param,
		'',
		'{"token":"response-secret","value":1}'
	);
	my $httpLogs = join("\n", map { $_->[2] } @logCalls);
	like($httpLogs, qr/HTTP REQUEST/, 'verbose 5 logs structured HTTP requests');
	like($httpLogs, qr/HTTP RESPONSE/, 'verbose 5 logs structured HTTP responses');
	unlike(
		$httpLogs,
		qr/(?:url-secret|auth-secret|key-secret|body-secret|cookie-secret|response-secret)/,
		'verbose 5 never logs supplied secrets in clear text'
	);
};

subtest 'initialization and lifecycle' => sub {
	resetContext();
	my $existing = newDevice(VIOLET_CONFIG_DISCOVERED_AT => 42);
	my $module = {};
	VIOLET_Initialize($module);

	is($module->{DefFn}, 'VIOLET_Define', 'Define callback is registered');
	is($module->{SetFn}, 'VIOLET_Set', 'Set callback is registered');
	is($data{FWEXT}{'/VIOLET'}{FUNC}, 'VIOLET_Push', 'push callback is registered');
	is($existing->{VIOLET_CONFIG_DISCOVERED_AT}, 0, 'reload invalidates discovery cache');

	my $invalid = {};
	like(
		VIOLET_Define($invalid, 'pool VIOLET'),
		qr/^Usage:/,
		'invalid definition is rejected'
	);

	my $hash = newDevice();
	is(VIOLET_Define($hash, 'pool VIOLET 192.0.2.10'), undef, 'valid definition succeeds');
	is($hash->{HOST}, '192.0.2.10', 'definition stores controller host');
	is($hash->{STATE}, 'credentials_required', 'definition starts without credentials');
	ok(@removedTimers, 'definition clears old timers');

	@removedTimers = ();
	is(VIOLET_Undef($hash, 'pool'), undef, 'undefinition succeeds');
	is(scalar(@removedTimers), 1, 'undefinition removes its timer');

	configureCredentials($hash);
	my $global = {NAME => 'global', EVENTS => ['INITIALIZED']};
	is(VIOLET_Notify($hash, $global), undef, 'initialization notification succeeds');
	ok(@timers, 'initialization with credentials schedules polling');
};

subtest 'credentials and attributes' => sub {
	resetContext();
	my $hash = newDevice();
	configureCredentials($hash);
	my $staleSession = {
		VIOLET_AUTH_VALIDATED       => 1,
		VIOLET_AUTH_REJECTED        => 1,
		VIOLET_CONFIG_DISCOVERED_AT => 42,
		VIOLET_ACTIVE_PREFIXES      => {PUMP => 1},
		VIOLET_AUTO_QUERY           => 'PUMP',
		helper                      => {setCapabilities => {pump => 1}},
	};
	is(VIOLET_InvalidateSession($staleSession), undef, 'session invalidation succeeds');
	is(
		$staleSession,
		{VIOLET_CONFIG_DISCOVERED_AT => 0, helper => {}},
		'session invalidation clears authentication and discovery state'
	);

	is(
		[VIOLET_CredentialsInfo($hash)],
		['admin', 'secret', undef],
		'credential components are read without mutation'
	);
	ok(VIOLET_CredentialsReady($hash), 'complete credentials are ready');
	$hash->{VIOLET_AUTH_REJECTED} = 1;
	ok(!VIOLET_CredentialsReady($hash), 'rejected credentials are not ready');
	delete $hash->{VIOLET_AUTH_REJECTED};

	$hash->{VIOLET_AUTH_VALIDATED} = 1;
	is(VIOLET_UpdateCredentialState($hash), 'accepted', 'credential state reflects validation');
	is($hash->{READINGS}{authState}{VAL}, 'accepted', 'credential state reading is updated');

	like(
		VIOLET_Attr('set', 'pool', 'interval', '4'),
		qr/integer >= 5/,
		'too-short polling interval is rejected'
	);
	like(VIOLET_Attr('set', 'pool', 'port', '70000'), qr/1\.\.65535/, 'invalid port is rejected');
	like(VIOLET_Attr('set', 'pool', 'timeout', '0'), qr/positive/, 'invalid timeout is rejected');
	like(
		VIOLET_Attr('set', 'pool', 'readingsQuery', 'ALL,INVALID'),
		qr/invalid values group/,
		'invalid manual readings query is rejected'
	);
	is(VIOLET_Attr('set', 'pool', 'interval', '60'), undef, 'valid polling interval succeeds');
};

subtest 'set and get command surfaces' => sub {
	resetContext();
	my $hash = newDevice();
	configureCredentials($hash);

	my @baseSetOptions = VIOLET_SetOptions($hash);
	ok(grep($_ eq 'password', @baseSetOptions), 'base Set options contain password');
	$hash->{helper}{setCapabilities} = {
		discovered => 1,
		pump => 1,
		pumpType => 2,
	};
	my @discoveredSetOptions = VIOLET_SetOptions($hash);
	ok(grep($_ eq 'pump:on,off,auto', @discoveredSetOptions), 'configured pump Set option is exposed');
	ok(grep($_ eq 'rs485Live', @discoveredSetOptions), 'RS485 option follows pump type');

	my @getOptions = VIOLET_GetOptions();
	ok(grep($_ eq 'outputs:noArg', @getOptions), 'Get options contain outputs');
	like(VIOLET_SetUsage($hash), qr/^Unknown argument/, 'Set usage is generated');
	like(VIOLET_GetUsage(), qr/^Unknown argument/, 'Get usage is generated');

	like(
		VIOLET_Set($hash, 'pool', 'pump', 'invalid'),
		qr/action must be/,
		'Set dispatcher validates output action'
	);
	like(
		VIOLET_Get($hash, 'pool', 'raw', 'relative'),
		qr/path must start/,
		'Get dispatcher validates raw path'
	);

	is(VIOLET_Get($hash, 'pool', 'outputs'), undef, 'Get dispatcher starts an output request');
	like(lastHttpCall()->{url}, qr{/getOutputstates$}, 'Get output endpoint is correct');
};

subtest 'command request builders' => sub {
	resetContext();
	my $hash = newDevice();
	configureCredentials($hash);

	is(VIOLET_SetFunction($hash, 'PUMP', 'ON', undef, undef), undef, 'function helper sends request');
	like(lastHttpCall()->{url}, qr{/setFunctionManually\?PUMP,ON,0,0$}, 'default function values are zero');

	is(VIOLET_SetFunctionRaw($hash, 'LIGHT', 'OFF', 2, 3), undef, 'raw function helper sends request');
	like(lastHttpCall()->{url}, qr{/setFunctionManually\?LIGHT,OFF,2,3$}, 'raw function values are retained');

	is(VIOLET_WriteConfig($hash, {KEY => 'x y'}, 'write config'), undef, 'configuration writer sends request');
	is(lastHttpCall()->{method}, 'POST', 'configuration writer uses POST');
	is(lastHttpCall()->{data}, 'KEY=x%20y', 'configuration writer form-encodes data');

	is(VIOLET_SetTarget($hash, 'unknown', 7), 'unknown target', 'unknown target is rejected');
	like(VIOLET_SetTarget($hash, 'ph', 9), qr/out of range/, 'out-of-range target is rejected');
	is(VIOLET_SetTarget($hash, 'ph', 7.2), undef, 'valid target starts configuration write');
	like(lastHttpCall()->{data}, qr/DOSAGE_phminus_setpoint=7\.2/, 'target maps to controller config key');

	is(VIOLET_SetCanister($hash, 'h2o2', 10, 'adjust'), 'unknown canister type', 'unmapped canister is rejected');
	is(VIOLET_SetCanister($hash, 'chlor', 10, 'adjust'), undef, 'valid canister request is sent');
	like(lastHttpCall()->{data}, qr/action=ADJUST/, 'canister action is normalized');

	is(VIOLET_ManualDosing($hash, 'DOS_1_CL', 0, 'DOSSTART', 65), undef, 'manual dosing request is sent');
	like(lastHttpCall()->{data}, qr/runtime_formatted=01%3A05/, 'manual dosing duration is formatted');

	$attr{pool}{disable} = 1;
	is(VIOLET_Request($hash, method => 'GET', path => '/status'), 'device is disabled', 'disabled request is blocked');
	delete $attr{pool}{disable};
	is(VIOLET_Request($hash, method => 'GET', path => '/status', purpose => 'status'), undef, 'authenticated request is queued');
	like(lastHttpCall()->{header}, qr/^Authorization: Basic /m, 'request contains Basic authentication');
	unlike(lastHttpCall()->{header}, qr/secret/, 'request header does not contain cleartext password');
};

subtest 'configuration and hardware discovery' => sub {
	resetContext();
	my $hash = newDevice();
	my %config = (
		MENU_control_1 => 1,
		MENU_control_2 => 1,
		MENU_dosage_1 => 1,
		PUMP_type => 2,
		NAMES_EXT1_1 => 'Jet',
		NAMES_onewire1 => 'Pool',
		DOSAGE_phminus_setpoint => 7.1,
	);

	my $capabilities = VIOLET_BuildSetCapabilities($hash, \%config);
	ok($capabilities->{pump}, 'configuration discovers pump capability');
	is($capabilities->{pumpType}, 2, 'configuration discovers pump type');
	ok($capabilities->{ext1_1}, 'configuration discovers named extension relay');
	$hash->{helper}{setCapabilities} = $capabilities;

	VIOLET_UpdateHardwareCapabilities(
		$hash,
		{
			PUMP => 1,
			SYSTEM_dosagemodule_alive_count => 1,
			SYSTEM_ext1module_alive_count => 1,
		}
	);
	ok($capabilities->{baseHardware}, 'readings confirm base hardware');
	ok($capabilities->{dosingHardware}, 'readings confirm dosing hardware');
	ok($capabilities->{ext1Hardware}, 'alive counter confirms extension hardware');

	my (%tokens, %allowed);
	VIOLET_AddActivePrefix(\%tokens, \%allowed, 'pH');
	ok($tokens{pH}, 'active prefix is added to controller query');
	ok($allowed{PH}, 'active prefix is added to local allow-list');

	$hash->{VIOLET_AUTO_QUERY} = 'SYSTEM';
	$hash->{VIOLET_ACTIVE_PREFIXES} = {};
	VIOLET_AddConfirmedExtensionPrefixes($hash);
	like($hash->{VIOLET_AUTO_QUERY}, qr/EXT1_1/, 'confirmed extension enters query');

	ok(
		VIOLET_ApplyHardwareDiscovery(
			$hash,
			'{"getReadings":{"SYSTEM_ext1module_alive_count":1,"PUMP":1}}'
		),
		'hardware discovery parses a wrapped readings response'
	);

	readingsBeginUpdate($hash);
	is(VIOLET_PublishConfigTargets($hash, \%config), 1, 'known configuration target is published');
	readingsEndUpdate($hash, 1);
	is($hash->{READINGS}{phTarget}{VAL}, 7.1, 'published target uses canonical reading name');

	ok(
		VIOLET_ApplyConfigDiscovery($hash, '{"getConfig":{"MENU_control_1":1,"PUMP_type":2}}'),
		'configuration discovery accepts wrapped JSON'
	);
	like($hash->{VIOLET_AUTO_QUERY}, qr/PUMP/, 'configuration discovery creates readings query');
	ok(VIOLET_IsActiveApiKey($hash, 'PUMP_state'), 'active API key is allowed');
	ok(!VIOLET_IsActiveApiKey($hash, 'UNUSED_state'), 'inactive API key is rejected');

	$attr{pool}{readingsQuery} = 'ALL, SYSTEM';
	is(VIOLET_EffectiveReadingsQuery($hash), 'ALL,SYSTEM', 'effective query removes presentation whitespace');
};

subtest 'automatic requests, polling and URLs' => sub {
	resetContext();
	my $hash = newDevice();

	like(
		VIOLET_RequestAutoValues($hash, 'poll'),
		qr/credentials are required/,
		'automatic values request requires credentials'
	);

	configureCredentials($hash);
	$hash->{VIOLET_AUTH_VALIDATED} = 1;
	$hash->{VIOLET_AUTO_QUERY} = 'PUMP, SYSTEM';
	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = time();
	is(VIOLET_RequestAutoValues($hash, 'poll'), undef, 'fresh discovery starts optimized readings request');
	like(lastHttpCall()->{url}, qr{/getReadings\?PUMP,SYSTEM$}, 'optimized query is used');

	$attr{pool}{useSSL} = 1;
	$attr{pool}{port} = 8443;
	is(VIOLET_BaseUrl($hash), 'https://violet.local:8443', 'base URL includes protocol and port');

	@timers = ();
	VIOLET_SchedulePoll($hash, 2);
	is($timers[-1][1], 'VIOLET_Poll', 'poll timer uses the expected callback');

	@httpCalls = ();
	@timers = ();
	VIOLET_Poll($hash);
	ok(@httpCalls, 'poll starts values request');
	ok(@timers, 'poll schedules its next run');
};

subtest 'HTTP result and reading processing' => sub {
	resetContext();
	my $hash = newDevice(CL => {NAME => 'client'});
	configureCredentials($hash);

	my $pretty = VIOLET_FormatGetOutput('{"b":2,"a":1}');
	like($pretty, qr/"a"\s*:\s*1/, 'explicit JSON output is formatted');
	like($pretty, qr/\n/, 'formatted JSON output is multiline');

	VIOLET_AsyncGetOutput(
		{violetReturnBody => 1, violetAsyncClient => $hash->{CL}},
		'result'
	);
	is($asyncOutputCalls[-1][1], 'result', 'asynchronous Get output reaches initiating client');

	ok(!VIOLET_ShouldUpdateReading($hash, 'new', 0, 0, 1), 'initial zero reading is suppressed');
	$hash->{READINGS}{same}{VAL} = 'x';
	ok(!VIOLET_ShouldUpdateReading($hash, 'same', 'x', 0, 0), 'unchanged reading is suppressed');
	ok(VIOLET_ShouldUpdateReading($hash, 'same', 'x', 1, 0), 'forced reading update is accepted');

	$unicodeEncoding = 1;
	is(VIOLET_FhemValue(undef), '', 'undefined FHEM value becomes empty string');
	is(VIOLET_FhemValue("plain"), 'plain', 'plain FHEM value remains stable');
	$unicodeEncoding = 0;
	is(VIOLET_FhemValue('plain'), 'plain', 'byte-stream value remains stable');
	$unicodeEncoding = 1;

	ok(VIOLET_BulkUpdateReading($hash, 'bulkValue', 3, 0, 0), 'bulk reading wrapper writes changed value');
	is($hash->{READINGS}{bulkValue}{VAL}, 3, 'bulk reading value is stored');
	ok(VIOLET_SingleUpdateReading($hash, 'singleValue', 4, 0, 0), 'single reading wrapper writes changed value');
	is($hash->{READINGS}{singleValue}{VAL}, 4, 'single reading value is stored');

	VIOLET_ParseJsonToReadings($hash, '{"TEMP_VALUE":24,"EMPTY":0}', '', 0);
	is($hash->{READINGS}{temp}{VAL}, 24, 'JSON response creates canonical reading');
	ok(!exists($hash->{READINGS}{empty}), 'initial zero JSON value remains suppressed');

	is(VIOLET_CanonicalApiKey('DOS_1_CL_RUNTIME'), 'DOSAGE_CHLOR_RUNTIME', 'chemical API key is canonicalized');
	is(
		VIOLET_CanonicalApiKey('DIGITALINPUTRULE_STATE_DIGITALINPUT_RULE_STOPWATCH1'),
		'DI1_RULE_STOPWATCH_STATE',
		'digital input rule with outer state is canonicalized'
	);
	is(
		VIOLET_CanonicalApiKey('DIGITALINPUTRULE_DIGITALINPUT_RULE_STOPWATCH1'),
		'DI1_RULE_STOPWATCH',
		'digital input rule without outer state is canonicalized'
	);
	is(VIOLET_CamelCaseReading('TEMP_VALUE_MAX'), 'tempMax', 'API key becomes lower camel case');
	is(VIOLET_PrefixedReading('output', 'PUMP_STATE'), 'outputPumpState', 'reading prefix is applied');

	my $transportParam = {
		hash => $hash,
		code => 0,
		violetPurpose => 'test',
		violetReturnBody => 0,
	};
	VIOLET_HttpCallback($transportParam, 'network down', '');
	is($hash->{READINGS}{connection}{VAL}, 'error', 'transport error updates connection reading');

	my $successParam = {
		hash => $hash,
		code => 200,
		violetPurpose => 'test',
		violetReturnBody => 0,
	};
	VIOLET_HttpCallback($successParam, '', '{}');
	is($hash->{READINGS}{connection}{VAL}, 'connected', 'successful response updates connection reading');
};

subtest 'push receiver' => sub {
	resetContext();
	my $hash = newDevice();

	is(
		[VIOLET_PushResponse($hash, 1)],
		['text/plain; charset=utf-8', 'OK'],
		'push response has direct-call fallback'
	);

	$FW_chash = {NAME => 'web-client'};
	is([VIOLET_PushResponse($hash, 0)], [undef, undef], 'FHEMWEB push response is written directly');
	like($tcpWrites[-1][1], qr/Content-Length: 5\r\n/, 'push response has numeric content length');
	like($tcpWrites[-1][1], qr/ERROR$/, 'failed push response body is exact');
	$FW_chash = undef;

	is(
		[VIOLET_Push('/fhem/VIOLET?device=unknown&TEMP=20')],
		['text/plain; charset=utf-8', 'ERROR'],
		'push for unknown device is rejected'
	);

	is(
		[VIOLET_Push('/fhem/VIOLET?device=pool&TEMP_VALUE=24')],
		['text/plain; charset=utf-8', 'OK'],
		'valid push is accepted'
	);
	is($hash->{READINGS}{temp}{VAL}, 24, 'valid push creates canonical reading');
};

subtest 'credential lifecycle edge cases' => sub {
	resetContext();
	my $hash = newDevice();

	is(VIOLET_UpdateCredentialState($hash), 'missing_username', 'missing username is reported');
	is($hash->{READINGS}{state}{VAL}, 'missing_username', 'missing username updates device state reading');
	$attr{pool}{username} = 'admin';
	is(VIOLET_UpdateCredentialState($hash), 'missing_password', 'missing password is reported');
	$keyValueReadError = 'store unavailable';
	is(VIOLET_UpdateCredentialState($hash), 'storage_error', 'credential storage error is reported');
	$keyValueReadError = undef;
	$keyValues{'VIOLET_PASSWORD_pool'} = 'secret';
	is(VIOLET_UpdateCredentialState($hash), 'configured', 'complete unvalidated credentials are reported');
	$hash->{VIOLET_AUTH_REJECTED} = 1;
	is(VIOLET_UpdateCredentialState($hash), 'rejected', 'rejected credentials are reported');

	@timers = ();
	delete $hash->{VIOLET_AUTH_REJECTED};
	is(VIOLET_Attr('set', 'pool', 'username', 'new-user'), undef, 'username change is accepted');
	is($hash->{READINGS}{authUser}{VAL}, 'new-user', 'pending username reaches credential state');
	ok(@timers, 'complete changed credentials restart polling');

	@timers = ();
	is(VIOLET_Attr('del', 'pool', 'username', undef), undef, 'username deletion is accepted');
	is($hash->{READINGS}{authState}{VAL}, 'missing_username', 'username deletion updates authentication state');
	is(scalar(@timers), 0, 'username deletion does not schedule polling');

	is(VIOLET_Attr('set', 'missing', 'interval', '60'), undef, 'attribute for missing device is ignored');
	is(VIOLET_Notify($hash, undef), undef, 'missing notification source is ignored');
	is(VIOLET_Notify($hash, {NAME => 'other', EVENTS => ['INITIALIZED']}), undef, 'non-global notification is ignored');
	is(VIOLET_Notify($hash, {NAME => 'global', EVENTS => ['DEFINED other']}), undef, 'irrelevant global event is ignored');

	@timers = ();
	$attr{pool}{username} = 'admin';
	is(VIOLET_Notify($hash, {NAME => 'global', EVENTS => ['REREADCFG']}), undef, 'rereadcfg notification is handled');
	ok(@timers, 'rereadcfg with complete credentials schedules polling');
};

subtest 'password command edge cases' => sub {
	resetContext();
	my $hash = newDevice();

	like(VIOLET_Set($hash, 'pool', 'password'), qr/^Usage:/, 'password requires an argument');
	is(VIOLET_Set($hash, 'pool', 'password', ''), 'password must not be empty', 'empty password is rejected');
	$keyValueWriteError = 'write failed';
	like(
		VIOLET_Set($hash, 'pool', 'password', 'secret'),
		qr/error while saving password/,
		'password storage failure is returned'
	);
	is($hash->{READINGS}{authState}{VAL}, 'storage_error', 'password storage failure updates authentication state');

	$keyValueWriteError = undef;
	@timers = ();
	is(VIOLET_Set($hash, 'pool', 'password', 'secret'), undef, 'password without username is stored');
	is(scalar(@timers), 0, 'password without username does not start polling');

	$attr{pool}{username} = 'admin';
	@timers = ();
	is(VIOLET_Set($hash, 'pool', 'password', 'new secret'), undef, 'password with username is stored');
	is($keyValues{'VIOLET_PASSWORD_pool'}, 'new secret', 'password keeps embedded spaces');
	ok(@timers, 'complete credentials start polling after password change');
};

subtest 'complete successful Set dispatch matrix' => sub {
	resetContext();
	my $hash = newDevice();
	configureCredentials($hash);
	like(VIOLET_Set($hash, 'pool'), qr/^Unknown argument/, 'missing Set command returns usage');
	like(VIOLET_Set($hash, 'pool', 'unknown'), qr/^Unknown argument/, 'unknown Set command returns usage');

	my @setCases = (
		['target alias', ['targetPh', '7.2'], qr{/setConfig$}, 'POST'],
		['extension alias', ['ext1_1', 'on'], qr{/setFunctionManually\?EXT1_1,ON,0,0$}, 'GET'],
		['DMX alias', ['dmx1', 'auto'], qr{/setFunctionManually\?DMX_SCENE1,AUTO,0,0$}, 'GET'],
		['digital rule alias', ['diRule1', 'push'], qr{/setFunctionManually\?DIRULE_1,PUSH,0,0$}, 'GET'],
		['dose alias', ['doseChlor', '61'], qr{/triggerManualDosing$}, 'POST'],
		['dose stop alias', ['doseStopChlor'], qr{/triggerManualDosing$}, 'POST'],
		['dosage alias', ['dosageChlor', 'start'], qr{/setConfig$}, 'POST'],
		['legacy dosage alias', ['dosageEnableChlor', 'off'], qr{/setConfig$}, 'POST'],
		['canister alias', ['canisterChlorAdjust', '10'], qr{/setCanAmount$}, 'POST'],
		['service alias', ['serviceSupportTunnel', 'on'], qr{/enableSUPPORTTUNNEL$}, 'GET'],
		['calibration alias', ['calibrationRestoreChlor', '123'], qr{/restoreOldCalib$}, 'POST'],
		['pump output', ['pump', 'on', '60', '2'], qr{/setFunctionManually\?PUMP,ON,60,2$}, 'GET'],
		['solar output', ['solar', 'auto'], qr{/setFunctionManually\?SOLAR,AUTO,0,0$}, 'GET'],
		['rinse output', ['rinse', 'off'], qr{/setFunctionManually\?BACKWASHRINSE,OFF,0,0$}, 'GET'],
		['pump speed', ['pumpSpeed', '2', '30'], qr{/setFunctionManually\?PUMP,ON,30,2$}, 'GET'],
		['light output', ['light', 'color'], qr{/setFunctionManually\?LIGHT,COLOR,0,0$}, 'GET'],
		['PV surplus', ['pvSurplus', 'on', '2'], qr{/setFunctionManually\?PVSURPLUS,ON,2,0$}, 'GET'],
		['generic extension', ['ext', '2', '8', 'auto', '30'], qr{/setFunctionManually\?EXT2_8,AUTO,30,0$}, 'GET'],
		['generic DMX', ['dmx', '12', 'off'], qr{/setFunctionManually\?DMX_SCENE12,OFF,0,0$}, 'GET'],
		['all DMX', ['dmxAll', 'auto'], qr{/setFunctionManually\?DMX_SCENE1,ALLAUTO,0,0$}, 'GET'],
		['generic digital rule', ['diRule', '7', 'lock'], qr{/setFunctionManually\?DIRULE_7,LOCK,0,0$}, 'GET'],
		['generic target', ['target', 'orp', '700'], qr{/setConfig$}, 'POST'],
		['generic dose', ['dose', 'floc', '30'], qr{/triggerManualDosing$}, 'POST'],
		['generic dose stop', ['doseStop', 'floc'], qr{/triggerManualDosing$}, 'POST'],
		['generic dosage enable', ['dosageEnable', 'h2o2', 'on'], qr{/setConfig$}, 'POST'],
		['generic canister', ['canister', 'floc', '10', 'reset'], qr{/setCanAmount$}, 'POST'],
		['cover', ['cover', 'open'], qr{/setFunctionManually\?COVER_OPEN,PUSH,0,0$}, 'GET'],
		['omni', ['omni', '5'], qr{/setFunctionManually\?OMNI,OMNI_DC5,0,0$}, 'GET'],
		['RS485 live', ['rs485Live', 'model', '1', 'rpm', '1000'], qr{/setRS485Live\?model,1,rpm,1000$}, 'GET'],
		['RS485 done', ['rs485Done'], qr{/setRS485Live\?DONE$}, 'GET'],
		['output test', ['outputTest', 'PUMP', 'SWITCH', '2'], qr{/setOutputTestmode\?PUMP,SWITCH,2000$}, 'GET'],
		['generic calibration restore', ['calibrationRestore', 'pot', '123'], qr{/restoreOldCalib$}, 'POST'],
		['reset blocking', ['resetBlocking'], qr{/resetBlocking$}, 'GET'],
		['generic service', ['service', 'ssh', 'off'], qr{/disableSSH$}, 'GET'],
		['firmware update', ['firmwareUpdate'], qr{/initUpdate$}, 'GET'],
		['reboot', ['reboot'], qr{/reboot$}, 'GET'],
		['local restore', ['localRestore', 'backup', 'one'], qr{/doLocalRestore\?backup one$}, 'GET'],
		['manual backup', ['manualBackup'], qr{/doManualBackup$}, 'GET'],
		['network', ['network', 'NET_ip', '192.0.2.1'], qr{/setLanConfig$}, 'POST'],
		['network JSON', ['networkJson', '{"NET_ip":"192.0.2.2"}'], qr{/setLanConfig$}, 'POST'],
		['timezone', ['timezone', 'Europe/Berlin'], qr{/setTimezone$}, 'POST'],
		['generic function', ['function', 'LIGHT', 'on', '1', '2'], qr{/setFunctionManually\?LIGHT,ON,1,2$}, 'GET'],
		['raw GET', ['rawGet', '/diagnostic'], qr{/diagnostic$}, 'GET'],
		['raw POST', ['rawPost', '/diagnostic', 'a=b'], qr{/diagnostic$}, 'POST'],
	);

	# Jeder oeffentliche Dispatcher-Zweig muss genau einen passenden HTTP-Aufruf erzeugen.
	for my $case (@setCases) {
		my ($label, $arguments, $urlPattern, $method) = @$case;
		@httpCalls = ();
		is(VIOLET_Set($hash, 'pool', @$arguments), undef, "$label is accepted");
		is(scalar(@httpCalls), 1, "$label queues one request");
		like(lastHttpCall()->{url}, $urlPattern, "$label uses the expected endpoint");
		is(lastHttpCall()->{method}, $method, "$label uses the expected method");
	}

	like(lastHttpCall()->{header}, qr/Content-Type: application\/x-www-form-urlencoded/, 'POST request declares form content type');
};

subtest 'complete Get dispatch matrix' => sub {
	resetContext();
	my $hash = newDevice(CL => {NAME => 'client'});
	configureCredentials($hash);
	$hash->{VIOLET_AUTH_VALIDATED} = 1;
	$hash->{VIOLET_AUTO_QUERY} = 'PUMP, SYSTEM';
	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = time();

	my @getCases = (
		['automatic values', ['values'], qr{/getReadings\?PUMP,SYSTEM$}],
		['explicit values', ['values', 'ALL', 'SYSTEM'], qr{/getReadings\?ALL,SYSTEM$}],
		['single values group', ['valuesGroup', 'DOSAGE'], qr{/getReadings\?DOSAGE$}],
		['outputs', ['outputs'], qr{/getOutputstates$}],
		['config', ['config'], qr{/getConfig$}],
		['config query', ['config', 'PUMP_type'], qr{/getConfig\?PUMP_type$}],
		['config key', ['configKey', 'PUMP_type'], qr{/getConfig\?PUMP_type$}],
		['services', ['services'], qr{/getServiceStates$}],
		['local backups', ['localBackups'], qr{/restoreLocalBackup$}],
		['update state', ['updateState'], qr{/getUpdateState$}],
		['RS485 data', ['rs485Data', 'model'], qr{/getRS485PumpData\?model$}],
		['raw transport', ['raw', '/diagnostic'], qr{/diagnostic$}],
	);

	# Alle dokumentierten Get-Befehle werden bis zum korrekten API-Endpunkt verfolgt.
	for my $case (@getCases) {
		my ($label, $arguments, $urlPattern) = @$case;
		@httpCalls = ();
		is(VIOLET_Get($hash, 'pool', @$arguments), undef, "$label is accepted");
		is(scalar(@httpCalls), 1, "$label queues one request");
		like(lastHttpCall()->{url}, $urlPattern, "$label uses the expected endpoint");
	}

	like(VIOLET_Get($hash, 'pool', 'valuesGroup'), qr/^Usage:/, 'valuesGroup requires one group');
	like(VIOLET_Get($hash, 'pool', 'configKey'), qr/^Usage:/, 'configKey requires one key');
	like(VIOLET_Get($hash, 'pool', 'rs485Data'), qr/^Usage:/, 'rs485Data requires a model');
	like(VIOLET_Get($hash, 'pool', 'unknown'), qr/^Unknown argument/, 'unknown Get command returns usage');
};

subtest 'dynamic Set capability matrix' => sub {
	resetContext();
	my $hash = newDevice();
	$hash->{helper}{setCapabilities} = {
		discovered => 1,
		baseHardwareChecked => 1,
		baseHardware => 1,
		dosingHardwareChecked => 1,
		dosingHardware => 1,
		pump => 1,
		pumpType => 2,
		solar => 1,
		heater => 1,
		backwash => 1,
		refill => 1,
		light => 1,
		lightColor => 1,
		cover => 1,
		eco => 1,
		pvSurplus => 1,
		dmx => 1,
		dmxCount => 2,
		ext1HardwareChecked => 1,
		ext1Hardware => 1,
		ext1_1 => 1,
		diRule1 => 1,
		chem_chlor => 1,
		chem_electrolysis => 1,
		chem_phminus => 1,
		chem_phplus => 1,
		chem_floc => 1,
		chem_h2o2 => 1,
		chlorElectrode => 1,
		omni0 => 1,
		omni5 => 1,
	};
	my @options = VIOLET_SetOptions($hash);
	my $optionText = join(' ', @options);

	like($optionText, qr/pump:on,off,auto/, 'pump capability is exposed');
	like($optionText, qr/targetSolar:/, 'solar target capability is exposed');
	like($optionText, qr/targetHeater:/, 'heater target capability is exposed');
	like($optionText, qr/light:on,off,auto,color/, 'color light capability is exposed');
	like($optionText, qr/dmx2:on,off,auto/, 'configured DMX scene count is exposed');
	like($optionText, qr/ext1_1:on,off,auto/, 'confirmed extension relay is exposed');
	like($optionText, qr/diRule1:push,lock,unlock/, 'digital input rule is exposed');
	like($optionText, qr/doseChlor/, 'manual chlorine dosage is exposed');
	like($optionText, qr/dosageH2o2:start,stop/, 'H2O2 configuration is exposed');
	unlike($optionText, qr/doseH2o2/, 'unsupported H2O2 manual dosage remains hidden');
	like($optionText, qr/calibrationRestoreChlor/, 'chlorine electrode calibration is exposed');
	like($optionText, qr/omni:0,5/, 'configured omni positions are exposed');

	$hash->{helper}{setCapabilities}{baseHardware} = 0;
	my $withoutBase = join(' ', VIOLET_SetOptions($hash));
	unlike($withoutBase, qr/pump:on,off,auto/, 'missing base hardware hides pump command');
};

subtest 'request validation and response formatting' => sub {
	resetContext();
	my $hash = newDevice(CL => {NAME => 'client'});

	$keyValueReadError = 'read failed';
	like(
		VIOLET_Request($hash, method => 'GET', path => '/status'),
		qr/error while reading password/,
		'credential storage read error blocks request'
	);
	$keyValueReadError = undef;
	like(
		VIOLET_Request($hash, method => 'GET', path => '/status'),
		qr/credentials are required/,
		'incomplete credentials block request'
	);

	configureCredentials($hash);
	$hash->{VIOLET_AUTH_REJECTED} = 1;
	like(
		VIOLET_Request($hash, method => 'GET', path => '/status'),
		qr/authentication was rejected/,
		'previous authentication rejection blocks request'
	);
	delete $hash->{VIOLET_AUTH_REJECTED};

	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = 42;
	$attr{pool}{timeout} = 2.5;
	is(
		VIOLET_Request(
			$hash,
			method => 'POST',
			path => '/setConfig',
			data => '{"value":1}',
			contentType => 'application/json',
			purpose => 'custom',
			returnBody => 1,
		),
		undef,
		'custom POST request is queued'
	);
	is($hash->{VIOLET_CONFIG_DISCOVERED_AT}, 0, 'configuration write invalidates discovery timestamp');
	is(lastHttpCall()->{timeout}, 2.5, 'request uses configured timeout');
	like(lastHttpCall()->{header}, qr/Content-Type: application\/json/, 'request uses explicit content type');
	is(lastHttpCall()->{data}, '{"value":1}', 'request preserves explicit body');
	is(lastHttpCall()->{violetAsyncClient}, $hash->{CL}, 'request captures asynchronous client');

	is(VIOLET_FormatGetOutput(undef), '', 'undefined Get body becomes empty output');
	is(VIOLET_FormatGetOutput('plain text'), 'plain text', 'Unicode plain text is returned unchanged');
	my $utf8Bytes = encode('UTF-8', "Gr\x{fc}\x{df}e");
	is(VIOLET_FormatGetOutput($utf8Bytes), "Gr\x{fc}\x{df}e", 'UTF-8 byte response is decoded');
	my $windowsBytes = 'Gr'.pack('C', 0xfc).pack('C', 0xdf).'e';
	is(VIOLET_FormatGetOutput($windowsBytes), "Gr\x{fc}\x{df}e", 'Windows-1252 byte response is decoded');

	my $asyncCount = scalar(@asyncOutputCalls);
	VIOLET_AsyncGetOutput({}, 'ignored');
	VIOLET_AsyncGetOutput({violetReturnBody => 1}, 'ignored');
	is(scalar(@asyncOutputCalls), $asyncCount, 'asynchronous output requires flag and client');
	VIOLET_AsyncGetOutput(
		{violetReturnBody => 1, violetAsyncClient => $hash->{CL}},
		undef
	);
	is($asyncOutputCalls[-1][1], '', 'undefined asynchronous output becomes empty text');
};

subtest 'HTTP callback error and output branches' => sub {
	resetContext();
	my $hash = newDevice(CL => {NAME => 'client'});
	configureCredentials($hash);

	is(VIOLET_HttpCallback({}, '', ''), undef, 'callback without device hash is ignored');
	$hash->{VIOLET_CONFIG_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'poll';
	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 0,
			violetPurpose => 'discoverConfig',
			violetReturnBody => 1,
			violetAsyncClient => $hash->{CL},
		},
		'connection refused',
		''
	);
	ok(!exists($hash->{VIOLET_CONFIG_DISCOVERY_PENDING}), 'config transport error releases discovery lock');
	ok(!exists($hash->{VIOLET_PENDING_VALUES_PURPOSE}), 'config transport error clears pending purpose');
	is($asyncOutputCalls[-1][1], 'ERROR: connection refused', 'transport error reaches Get client');

	$hash->{VIOLET_HARDWARE_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'poll';
	VIOLET_HttpCallback(
		{hash => $hash, code => 0, violetPurpose => 'discoverHardware'},
		'timeout',
		''
	);
	ok(!exists($hash->{VIOLET_HARDWARE_DISCOVERY_PENDING}), 'hardware transport error releases discovery lock');

	$hash->{VIOLET_AUTH_VALIDATED} = 1;
	$hash->{VIOLET_CONFIG_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_HARDWARE_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'poll';
	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 401,
			violetPurpose => 'getValues',
			violetReturnBody => 1,
			violetAsyncClient => $hash->{CL},
		},
		'',
		''
	);
	ok($hash->{VIOLET_AUTH_REJECTED}, 'HTTP 401 marks credentials rejected');
	ok(!exists($hash->{VIOLET_AUTH_VALIDATED}), 'HTTP 401 clears validation');
	is($hash->{READINGS}{authState}{VAL}, 'rejected', 'HTTP 401 updates authentication reading');
	is($asyncOutputCalls[-1][1], 'ERROR: HTTP 401', 'HTTP 401 reaches Get client');
	ok(@removedTimers, 'HTTP 401 removes polling timer');

	delete $hash->{VIOLET_AUTH_REJECTED};
	@asyncOutputCalls = ();
	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 500,
			violetPurpose => 'getConfig',
			violetReturnBody => 1,
			violetAsyncClient => $hash->{CL},
		},
		'',
		'{"error":"broken"}'
	);
	like($asyncOutputCalls[-1][1], qr/^ERROR: HTTP 500\n/, 'HTTP error body reaches Get client');
	is($hash->{READINGS}{state}{VAL}, 'http_500', 'HTTP 500 updates device state');
	VIOLET_HttpCallback(
		{hash => $hash, code => 404, violetPurpose => 'missing'},
		'',
		''
	);
	is($hash->{READINGS}{state}{VAL}, 'http_404', 'HTTP client error updates device state');

	@asyncOutputCalls = ();
	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 200,
			violetPurpose => 'getConfig',
			violetReturnBody => 1,
			violetAsyncClient => $hash->{CL},
		},
		'',
		'{"b":2,"a":1}'
	);
	like($asyncOutputCalls[-1][1], qr/"a"\s*:\s*1/, 'successful Get body is formatted for client');
	ok($hash->{VIOLET_AUTH_VALIDATED}, 'successful callback validates credentials');

	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 200,
			violetPurpose => 'getValues',
			violetParseReadings => 1,
			violetActiveFilter => 0,
		},
		'',
		'{"TEMP_VALUE":23}'
	);
	is($hash->{READINGS}{temp}{VAL}, 23, 'successful reading callback parses values');
	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 200,
			violetPurpose => 'getServices',
			violetParsePrefix => 'service',
		},
		'',
		'{"SSH_STATE":"on"}'
	);
	is($hash->{READINGS}{serviceSshState}{VAL}, 'on', 'successful prefixed callback parses values');

	$hash->{VIOLET_AUTO_QUERY} = 'PUMP';
	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = time();
	@httpCalls = ();
	VIOLET_HttpCallback(
		{
			hash => $hash,
			code => 200,
			violetPurpose => 'write',
			violetRefresh => 1,
		},
		'',
		'{}'
	);
	is(scalar(@httpCalls), 1, 'successful write callback starts refresh request');
	is(lastHttpCall()->{violetPurpose}, 'refreshAfterSet', 'write refresh has dedicated purpose');
};

subtest 'discovery callback chain' => sub {
	resetContext();
	my $hash = newDevice();
	configureCredentials($hash);
	$hash->{VIOLET_CONFIG_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'getValues';

	VIOLET_HttpCallback(
		{hash => $hash, code => 200, violetPurpose => 'discoverConfig'},
		'',
		'{"getConfig":{"MENU_control_1":1,"PUMP_type":2}}'
	);
	ok($hash->{VIOLET_HARDWARE_DISCOVERY_PENDING}, 'successful config discovery starts hardware discovery');
	like(lastHttpCall()->{url}, qr{/getReadings\?ALL$}, 'hardware discovery uses unfiltered ALL query');

	VIOLET_HttpCallback(
		{hash => $hash, code => 200, violetPurpose => 'discoverHardware'},
		'',
		'{"getReadings":{"PUMP_STATE":"on"}}'
	);
	ok(!exists($hash->{VIOLET_HARDWARE_DISCOVERY_PENDING}), 'successful hardware discovery releases lock');
	is(lastHttpCall()->{violetPurpose}, 'getValues', 'hardware discovery resumes original request purpose');
	ok(lastHttpCall()->{violetActiveFilter}, 'resumed optimized values request enables active filter');

	resetContext();
	$hash = newDevice();
	configureCredentials($hash);
	$hash->{VIOLET_CONFIG_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'poll';
	VIOLET_HttpCallback(
		{hash => $hash, code => 200, violetPurpose => 'discoverConfig'},
		'',
		'not-json'
	);
	is(
		$hash->{VIOLET_AUTO_QUERY},
		'ALL, DOSAGE, RUNTIMES, PUMPPRIOSTATE, BACKWASH, SYSTEM',
		'invalid config discovery installs broad fallback query'
	);
	ok(!lastHttpCall()->{violetActiveFilter}, 'fallback values request disables active filter');

	$hash->{VIOLET_CONFIG_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'poll';
	VIOLET_HttpCallback(
		{hash => $hash, code => 503, violetPurpose => 'discoverConfig'},
		'',
		''
	);
	ok(!exists($hash->{VIOLET_CONFIG_DISCOVERY_PENDING}), 'failed config HTTP response releases discovery lock');
	ok(!exists($hash->{VIOLET_PENDING_VALUES_PURPOSE}), 'failed config HTTP response clears pending purpose');

	$hash->{VIOLET_HARDWARE_DISCOVERY_PENDING} = 1;
	$hash->{VIOLET_PENDING_VALUES_PURPOSE} = 'poll';
	@httpCalls = ();
	VIOLET_HttpCallback(
		{hash => $hash, code => 500, violetPurpose => 'discoverHardware'},
		'',
		''
	);
	is(scalar(@httpCalls), 1, 'failed hardware HTTP response still resumes values request');
};

subtest 'polling and automatic discovery edge cases' => sub {
	resetContext();
	my $hash = newDevice();

	is(VIOLET_Poll(undef), undef, 'poll without device is ignored');
	is(VIOLET_Poll($hash), undef, 'poll without credentials is ignored');
	is(scalar(@httpCalls), 0, 'poll without credentials sends no request');
	is(VIOLET_SchedulePoll(undef), undef, 'schedule without device is ignored');
	is(VIOLET_SchedulePoll($hash), undef, 'schedule without credentials is ignored');
	is(scalar(@timers), 0, 'schedule without credentials creates no timer');

	configureCredentials($hash);
	$attr{pool}{disable} = 1;
	is(VIOLET_Poll($hash), undef, 'disabled poll is skipped');
	is(scalar(@httpCalls), 0, 'disabled poll sends no request');
	is(scalar(@timers), 0, 'disabled poll schedules no timer');
	delete $attr{pool}{disable};
	$attr{pool}{interval} = 0;
	is(VIOLET_SchedulePoll($hash), undef, 'zero interval disables timer');
	is(scalar(@timers), 0, 'zero interval creates no timer');
	delete $attr{pool}{interval};

	is(VIOLET_BaseUrl($hash), 'http://violet.local', 'base URL defaults to HTTP without port');
	$hash->{VIOLET_AUTH_VALIDATED} = 1;
	$attr{pool}{readingsQuery} = 'ALL, SYSTEM';
	@httpCalls = ();
	is(VIOLET_RequestAutoValues($hash, 'manual'), undef, 'manual readings query starts immediately');
	like(lastHttpCall()->{url}, qr{/getReadings\?ALL,SYSTEM$}, 'manual readings query is normalized');
	ok(!lastHttpCall()->{violetActiveFilter}, 'manual readings query disables active filter');

	delete $attr{pool}{readingsQuery};
	delete $hash->{VIOLET_AUTH_VALIDATED};
	@httpCalls = ();
	is(VIOLET_RequestAutoValues($hash, 'first'), undef, 'unvalidated credentials start config discovery');
	like(lastHttpCall()->{url}, qr{/getConfig$}, 'initial discovery starts with config endpoint');
	my $requestCount = scalar(@httpCalls);
	is(VIOLET_RequestAutoValues($hash, 'second'), undef, 'overlapping discovery request is collapsed');
	is(scalar(@httpCalls), $requestCount, 'overlapping discovery queues no second request');
	is($hash->{VIOLET_PENDING_VALUES_PURPOSE}, 'second', 'latest overlapping purpose is retained');
};

subtest 'complex configuration discovery' => sub {
	resetContext();
	my $hash = newDevice();
	my $configuration = <<'JSON';
{"getConfig":{"MENU_control_1":1,"MENU_control_7":1,"PUMP_type":2,"LIGHT_control_dmx":1,"LIGHT_control_max_dmx_pattern":20,"DOSAGE_phminus_use":1,"DOSAGE_electrolysis_use":1,"ECO_use":1,"NAMES_DMX_SCENE12":"Party","NAMES_onewire1":"Pool","ONEWIRE1_rom":"28-0001","NAMES_onewire2":"Solar","ONEWIRE2_rom":"28-0002","DOSAGE_phminus_setpoint":7.1}}
JSON

	ok(VIOLET_ApplyConfigDiscovery($hash, $configuration), 'complex configuration discovery succeeds');
	is($hash->{helper}{setCapabilities}{dmxCount}, 12, 'DMX scene count is capped at controller maximum');
	like($hash->{VIOLET_AUTO_QUERY}, qr/DOSAGE/, 'active chemistry adds dosage query group');
	like($hash->{VIOLET_AUTO_QUERY}, qr/DOS_2_CURRENT/, 'electrolysis adds polarity query');
	like($hash->{VIOLET_AUTO_QUERY}, qr/DOS_3_ELO_REV/, 'electrolysis adds reverse channel query');
	like($hash->{VIOLET_AUTO_QUERY}, qr/DMX_SCENE12/, 'named DMX scene is included');
	like($hash->{VIOLET_AUTO_QUERY}, qr/onewire1/, 'configured OneWire sensor is included');
	is($hash->{READINGS}{onewire1Name}{VAL}, 'Pool', 'OneWire display name is published');
	is($hash->{READINGS}{onewire2Name}{VAL}, 'Solar', 'second OneWire display name is published');
	is($hash->{READINGS}{phTarget}{VAL}, 7.1, 'discovered target is published');
	ok(VIOLET_IsActiveApiKey($hash, 'DOS_2_CURRENT_POLARITY'), 'electrolysis polarity passes active filter');
	ok(VIOLET_IsActiveApiKey($hash, 'ECO_STATE'), 'generic enabled feature passes active filter');

	ok(!VIOLET_ApplyHardwareDiscovery($hash, 'broken'), 'invalid hardware discovery JSON is rejected');
	is(VIOLET_BuildSetCapabilities($hash, []), {}, 'invalid capability input returns empty profile');
};

subtest 'reading normalization and filtering edge cases' => sub {
	resetContext();
	my $hash = newDevice();

	$hash->{READINGS}{change}{VAL} = 'old';
	ok(VIOLET_ShouldUpdateReading($hash, 'change', 'new', 0, 0), 'changed reading is updated');
	$hash->{READINGS}{empty}{VAL} = undef;
	ok(!VIOLET_ShouldUpdateReading($hash, 'empty', undef, 0, 0), 'equivalent undefined reading remains unchanged');
	is(VIOLET_FhemValue([]), [], 'reference reading value is passed through');
	$unicodeEncoding = 1;
	is(VIOLET_FhemValue(encode('UTF-8', "M\x{fc}ller")), "M\x{fc}ller", 'UTF-8 reading bytes become Unicode');
	is(VIOLET_FhemValue('M'.pack('C', 0xfc).'ller'), "M\x{fc}ller", 'Windows-1252 reading bytes become Unicode');
	$unicodeEncoding = 0;
	my $unicodeReading = "M\x{fc}ller";
	utf8::upgrade($unicodeReading);
	is(VIOLET_FhemValue($unicodeReading), encode('UTF-8', $unicodeReading), 'Unicode reading becomes UTF-8 in byte mode');
	$unicodeEncoding = 1;

	VIOLET_ParseJsonToReadings($hash, 'broken', '', 0);
	is($hash->{READINGS}{lastError}{VAL}, 'invalid JSON response', 'invalid reading JSON is reported');
	VIOLET_ParseJsonToReadings(
		$hash,
		'{"getReadings":{"EXT1_1_STATE":"on","EXT2_1_STATE":"on","SYSTEM_ext1module_alive_count":1}}',
		'',
		0
	);
	is($hash->{READINGS}{ext11State}{VAL}, 'on', 'confirmed extension placeholder becomes reading');
	ok(!exists($hash->{READINGS}{ext21State}), 'unconfirmed extension placeholder is filtered');

	$hash->{VIOLET_ACTIVE_PREFIXES} = {PUMP => 1};
	$hash->{VIOLET_CONFIG_DISCOVERED_AT} = 42;
	$hash->{VIOLET_CONFIG_CHANGE_MARKER} = 'old';
	VIOLET_ParseJsonToReadings(
		$hash,
		'{"PUMP_STATE":"auto","UNUSED_STATE":"on","CONFIGCHANGEMARKER":"new"}',
		'',
		1
	);
	is($hash->{READINGS}{pumpState}{VAL}, 'auto', 'active reading survives filter');
	ok(!exists($hash->{READINGS}{unusedState}), 'inactive reading is filtered');
	is($hash->{VIOLET_CONFIG_DISCOVERED_AT}, 0, 'changed config marker invalidates discovery');
	ok(!exists($hash->{READINGS}{configchangemarker}), 'config marker is not published');

	is(VIOLET_CanonicalApiKey('POT_VALUE'), 'CHLOR_VALUE', 'chlorine sensor key is canonicalized');
	is(
		VIOLET_CanonicalApiKey('DOS_2_CURRENT_POLARITY'),
		'DOSAGE_ELECTROLYSIS_POLARITY',
		'electrolysis polarity is canonicalized'
	);
	is(
		VIOLET_CanonicalApiKey('DOS_3_ELO_REV_LAST_ON'),
		'DOSAGE_ELECTROLYSIS_REVERSE_LAST_ON',
		'electrolysis reverse channel is canonicalized'
	);
	is(
		VIOLET_CanonicalApiKey('DIGITALINPUTRULE_STATE_DIGITALINPUT_RULE_READY'),
		'DI_RULE_READY_STATE',
		'non-numbered digital input field remains deterministic'
	);
	is(VIOLET_CanonicalApiKey('DOSAGE_phminus_use'), 'DOSAGE_PHMINUS_use', 'dosage configuration key is canonicalized');
	is(VIOLET_CamelCaseReading('1_VALUE'), 'value1', 'numeric reading name receives text prefix');
	is(VIOLET_CamelCaseReading(''), 'value', 'empty reading name receives fallback');
	is(VIOLET_CamelCaseReading('TEMP_VALUE_MIN'), 'tempMin', 'minimum value suffix is shortened');
	is(VIOLET_PrefixedReading('config', 'NAMES_onewire2'), 'onewire2Name', 'OneWire config name uses sensor metadata reading');

	ok(VIOLET_IsActiveApiKey({VIOLET_ACTIVE_PREFIXES => {}}, 'ANY_KEY'), 'empty active filter allows values');
	ok(!VIOLET_IsActiveApiKey($hash, 'CONFIGCHANGEMARKER'), 'config marker is rejected by active filter');
	is(VIOLET_EffectiveReadingsQuery(newDevice(NAME => 'empty')), undef, 'missing automatic query remains undefined');
};

subtest 'push authentication and error normalization' => sub {
	resetContext();
	my $hash = newDevice();
	$attr{pool}{token} = 'expected';

	is(
		[VIOLET_Push('/fhem/VIOLET?device=pool&token=wrong&TEMP=20')],
		['text/plain; charset=utf-8', 'ERROR'],
		'push with wrong token is rejected'
	);
	is($hash->{READINGS}{pushAuthState}{VAL}, 'rejected', 'wrong push token updates authentication reading');
	is(
		[VIOLET_Push('/fhem/VIOLET?device=pool&token=expected')],
		['text/plain; charset=utf-8', 'ERROR'],
		'push without payload is rejected'
	);

	is(
		[VIOLET_Push('/fhem/VIOLET?DEVICE=pool&TOKEN=expected&ERRORCODE=0020&SUBJECT=Pump+blocked')],
		['text/plain; charset=utf-8', 'OK'],
		'authenticated uppercase error push is accepted'
	);
	is($hash->{READINGS}{errorCode}{VAL}, '0020', 'error code preserves leading zeroes');
	is($hash->{READINGS}{errorInfo}{VAL}, 'Pump blocked', 'error subject becomes error information');
	is($hash->{READINGS}{errorType}{VAL}, 'ALERT', 'error type metadata is published');
	ok(!exists($hash->{READINGS}{subject}), 'raw error subject is not duplicated');

	is(
		[VIOLET_Push('/fhem/VIOLET?device=pool&token=expected&errorcode=81&subject=Program+1')],
		['text/plain; charset=utf-8', 'OK'],
		'lowercase error push is accepted'
	);
	is($hash->{READINGS}{errorCode}{VAL}, '81', 'lowercase error code is normalized');
	is($hash->{READINGS}{pushAuthState}{VAL}, 'accepted', 'valid token updates push authentication reading');

	$readingBulkError = 'synthetic reading failure';
	is(
		[VIOLET_Push('/fhem/VIOLET?device=pool&token=expected&TEMP=20')],
		['text/plain; charset=utf-8', 'ERROR'],
		'unexpected reading failure becomes a safe push error'
	);
	is($readingFlow[-1][0], 'end', 'failed push closes reading update block');
	is($readingFlow[-1][2], 0, 'failed push closes reading update block without trigger');
};

done_testing();
