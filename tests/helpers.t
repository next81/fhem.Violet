# Copyright (c) 2026 Andreas Planer
# GitHub: https://github.com/next81/fhem.Violet
# FHEM-Forum: https://forum.fhem.de/index.php?action=profile;u=45773

use strict;
use warnings;

use Test2::V0;
use lib 'lib';

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

is(
	VIOLET_BroadReadingsQuery(),
	'ALL,DOSAGE,RUNTIMES,PUMPPRIOSTATE,BACKWASH,SYSTEM',
	'broad readings query is stable'
);

ok(VIOLET_ConfigValueEnabled('2'), 'positive configuration mode is enabled');
ok(!VIOLET_ConfigValueEnabled(' disabled '), 'disabled configuration value is rejected');
is(
	VIOLET_ConfigFlatValue({'MENU-control-1' => 'yes'}, 'MENU_control_1'),
	'yes',
	'flat configuration lookup normalizes keys'
);

my ($decoded, $decodeError) = VIOLET_DecodeJsonResponse('{"nested":{"value":1}}');
is($decodeError, undef, 'valid JSON has no decode error');
is($decoded->{nested}{value}, 1, 'JSON response is decoded');

my %flat;
VIOLET_Flatten('', {nested => {value => 1}, list => [1, 2]}, \%flat);
is(
	\%flat,
	{nested_value => 1, list => '[1,2]'},
	'nested JSON values are flattened'
);

is(VIOLET_FormEncode({b => 'x y', a => 1}), 'a=1&b=x%20y', 'form values are sorted and escaped');
ok(VIOLET_IsInitialEmptyOrZero('0e0'), 'initial scientific zero is suppressed');
ok(!VIOLET_IsInitialEmptyOrZero('0.1'), 'non-zero value is retained');
ok(VIOLET_IsUInt('42'), 'unsigned integer is accepted');
ok(!VIOLET_IsUInt('-1'), 'negative integer is rejected');
ok(VIOLET_IsNumber('-.5'), 'plain decimal is accepted');
ok(!VIOLET_IsNumber('1e2'), 'exponent notation is rejected');
is(VIOLET_LogValue("a\nb\t"), 'a\\nb\\t', 'log value escapes control characters');
is(VIOLET_LogValue(undef), '<undef>', 'undefined log value is explicit');
is(VIOLET_LogValue([]), '<ARRAY>', 'reference log value exposes only its type');

ok(!VIOLET_ConfigValueEnabled(undef), 'undefined configuration value is disabled');
ok(!VIOLET_ConfigValueEnabled('  '), 'empty configuration value is disabled');
ok(!VIOLET_ConfigValueEnabled('0.00'), 'numeric zero configuration value is disabled');
ok(VIOLET_ConfigValueEnabled('configured'), 'non-empty configuration value is enabled');
is(VIOLET_ConfigFlatValue([], 'KEY'), undef, 'non-hash configuration cannot be searched');
is(VIOLET_ConfigFlatValue({OTHER => 1}, 'KEY'), undef, 'missing configuration key stays undefined');

my ($missingJson, $missingJsonError) = VIOLET_DecodeJsonResponse(undef);
is($missingJson, undef, 'missing JSON response has no decoded value');
is($missingJsonError, 'empty response', 'missing JSON response has a stable error');
my ($invalidJson, $invalidJsonError) = VIOLET_DecodeJsonResponse('{broken');
is($invalidJson, undef, 'invalid JSON has no decoded value');
like($invalidJsonError, qr/at character offset/, 'invalid JSON returns the parser error');
my $windowsJson = '{"name":"M'.pack('C', 0xfc).'ller"}';
my ($windowsDecoded, $windowsError) = VIOLET_DecodeJsonResponse($windowsJson);
is($windowsError, undef, 'Windows-1252 JSON fallback has no decode error');
is($windowsDecoded->{name}, 'M'.chr(0xfc).'ller', 'Windows-1252 JSON fallback becomes Unicode');

my %query = VIOLET_ParseQuery('name=Pool+One&value=10%25');
is(\%query, {name => 'Pool One', value => '10%'}, 'query string is decoded');
is(VIOLET_UrlDecode('a%2Bb+c'), 'a+b c', 'URL component is decoded');
is(VIOLET_SanitizeReading(' DOSAGE-pH value '), 'DOSAGE_pH_value', 'reading name is sanitized');
is(VIOLET_SanitizeReading('---'), 'value', 'empty sanitized reading receives fallback name');
is(VIOLET_SanitizeReading(undef), 'value', 'undefined reading receives fallback name');
my %semicolonQuery = VIOLET_ParseQuery('=discarded;empty=;name=value');
is(
	\%semicolonQuery,
	{empty => '', name => 'value'},
	'query parser accepts semicolons and discards empty keys'
);
is(VIOLET_UrlDecode(undef), '', 'undefined URL component becomes empty text');
is(VIOLET_FormEncode({empty => undef}), 'empty=', 'undefined form value becomes empty text');

ok(VIOLET_IsInitialEmptyOrZero(undef), 'undefined initial value is suppressed');
ok(VIOLET_IsInitialEmptyOrZero('NO_SENSOR_CONFIGURED'), 'unconfigured sensor marker is suppressed');
ok(VIOLET_IsInitialEmptyOrZero('0d 0h 0m 0s'), 'zero duration is suppressed');
ok(VIOLET_IsInitialEmptyOrZero('00:00:00'), 'zero clock duration is suppressed');
ok(VIOLET_IsInitialEmptyOrZero('[]'), 'empty array text is suppressed');
ok(VIOLET_IsInitialEmptyOrZero('{}'), 'empty object text is suppressed');
ok(!VIOLET_IsInitialEmptyOrZero('1m'), 'non-zero duration is retained');
ok(!VIOLET_IsUInt(undef), 'undefined unsigned integer is rejected');
ok(!VIOLET_IsUInt('1.0'), 'decimal unsigned integer is rejected');
ok(!VIOLET_IsNumber(undef), 'undefined number is rejected');
ok(VIOLET_IsNumber('+1.'), 'signed decimal number is accepted');

my %scalarFlat;
VIOLET_Flatten('', undef, \%scalarFlat);
is(\%scalarFlat, {value => ''}, 'undefined root value is flattened to empty text');
my %objectFlat;
VIOLET_Flatten('', bless({}, 'TestObject'), \%objectFlat);
like($objectFlat{value}, qr/^TestObject=/, 'other references are flattened without traversal');

my @services = VIOLET_ServiceNames();
ok(grep($_ eq 'support_tunnel', @services), 'service list exposes support tunnel');
ok(VIOLET_ServiceExists('ssh'), 'known service exists');
ok(!VIOLET_ServiceExists('unknown'), 'unknown service does not exist');
is(VIOLET_ServiceApiSuffix('support_tunnel'), 'SUPPORTTUNNEL', 'API service suffix is built');
is(VIOLET_ServiceCommandSuffix('support_tunnel'), 'SupportTunnel', 'command suffix is built');
is(
	VIOLET_ServiceFromSetCommand('serviceSupportTunnel'),
	'support_tunnel',
	'direct service command is resolved'
);
is(VIOLET_ServicePath('ssh', 'on'), '/enableSSH', 'service endpoint is built');
is(VIOLET_ServicePath('ssh', 'off'), '/disableSSH', 'service disable endpoint is built');
is(VIOLET_ServicePath('unknown', 'on'), undef, 'unknown service has no endpoint');
is(VIOLET_ServiceFromSetCommand('serviceSSH'), 'ssh', 'service command matching ignores case');
is(VIOLET_ServiceFromSetCommand('serviceUnknown'), undef, 'unknown service command is rejected');

is(VIOLET_ValidateValueGroups('ALL,SYSTEM'), undef, 'known readings groups are valid');
like(
	VIOLET_ValidateValueGroups('ALL,UNKNOWN'),
	qr/^invalid values group:/,
	'unknown readings group is rejected'
);
is(
	VIOLET_ValidateValueGroups('ALL', 'SYSTEM'),
	undef,
	'multiple separate readings groups are valid'
);

done_testing();
