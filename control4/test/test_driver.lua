-- Run from the repository root:  lua5.1 control4/test/test_driver.lua
-- Loads driver.lua under a fake C4 runtime and walks through the main flows.

package.path = 'control4/test/?.lua;' .. package.path
local stub = require('c4stub')

Properties = {
	['Bridge Address'] = '192.168.1.50',
	['API Key'] = 'ABC123',
	['Shield MAC Address'] = '00:04:4b:aa:bb:cc',
	['Wake on Select'] = 'On',
	['Launch Delay (ms)'] = '0',
	['Rows'] = 'Continue + Up Next + New',
	['Max Items'] = '40',
	['Forward Remote Commands'] = 'To device on Video In',
	['After Launch'] = 'Go to Now Playing',
	['Refresh Interval (s)'] = '60',
	['Debug Mode'] = 'Off',
	['Bridge Status'] = '',
	['Driver Version'] = '',
}
stub.properties = Properties

dofile('control4/shield_bridge/driver.lua')

local passed, failed = 0, 0
local function check(cond, msg)
	if (cond) then passed = passed + 1 else failed = failed + 1 print('FAIL: ' .. msg) end
end
local function eq(a, b, msg)
	check(a == b, msg .. ' (got ' .. tostring(a) .. ', want ' .. tostring(b) .. ')')
end
local function find(s, pat, msg)
	check(type(s) == 'string' and s:find(pat, 1, true) ~= nil, msg .. ' (missing "' .. pat .. '" in ' .. tostring(s):sub(1, 200) .. ')')
end

------------------------------------------------------------------ JSON
do
	local v = JSON.decode('{"a":1,"b":[1,2,{"c":"x\\"y\\u00e9\\ud83d\\ude00"}],"d":true,"e":null,"f":-1.5e2,"g":""}')
	eq(v.a, 1, 'json number')
	eq(#v.b, 3, 'json array len')
	eq(v.b[3].c, 'x"y\195\169\240\159\152\128', 'json string escapes + utf8')
	eq(v.d, true, 'json true')
	eq(v.e, nil, 'json null dropped')
	eq(v.f, -150, 'json exp number')
	eq(v.g, '', 'json empty string')
	local bad, err = JSON.decode('{"a":')
	check(bad == nil and err ~= nil, 'json error reported')
	eq(JSON.encode({ id = 5, url = 'a"b', ok = true }), '{"id":5,"ok":true,"url":"a\\"b"}', 'json encode object sorted keys')
	eq(JSON.encode({ 1, 'two', false }), '[1,"two",false]', 'json encode array')
	eq(JSON.encode({}), '{}', 'json encode empty')
	local ws = JSON.decode('  \n{ "k" : [ ] , "m" : { } }  ')
	check(type(ws.k) == 'table' and #ws.k == 0 and type(ws.m) == 'table', 'json whitespace tolerant')
end

------------------------------------------------------------------ helpers
eq(BridgeBaseUrl(), 'http://192.168.1.50:8765', 'base url adds default port')
Properties['Bridge Address'] = 'http://shield.local:9000/'
eq(BridgeBaseUrl(), 'http://shield.local:9000', 'base url strips scheme and slash')
Properties['Bridge Address'] = '192.168.1.50'
eq(ShieldMac(), '00044baabbcc', 'mac normalised')
eq(FormatSeconds(3725), '1h 02m', 'format hours')
eq(FormatSeconds(300), '5m', 'format minutes')
eq(XMLEncode('a<b&"c"'), 'a&lt;b&amp;&quot;c&quot;', 'xml encode')
eq(BridgeHeaders()['X-Api-Key'], 'ABC123', 'api key header')

------------------------------------------------------------------ init
OnDriverLateInit()
check(stub.variables['BRIDGE_ONLINE'] == 'false', 'variables added')
eq(Properties['Driver Version'], DRIVER_VERSION, 'version property written')
check(#stub.urlRequests >= 1, 'status probe sent on init')
-- answer the status probe and the property-triggered fetches
while (#stub.urlRequests > 0) do
	stub.respond(200, '{"ok":true,"items":[],"apps":[]}')
end
eq(Bridge.online, true, 'bridge online after status')
check(stub.events[#stub.events] == 'Bridge Online', 'Bridge Online event fired')

------------------------------------------------------------------ continue list
local sampleContinue = [[
{"ok":true,"generatedAt":1,"total":3,"items":[
 {"id":101,"package":"com.netflix.ninja","app":"Netflix","title":"Severance","episodeTitle":"Hide and Seek","season":"2","episode":"4",
  "type":"TV_EPISODE","watchNextType":"CONTINUE","positionMs":1200000,"durationMs":3300000,"progress":36,"lastEngagementMs":5,
  "art":"http://192.168.1.50:8765/api/art/101","artWidth":200,"artHeight":300,"intentUri":"intent://www.netflix.com/title/81233755#Intent;scheme=https;end","browsable":true},
 {"id":102,"package":"com.disney.disneyplus","app":"Disney+","title":"Andor","season":"1","episode":"7",
  "type":"TV_EPISODE","watchNextType":"NEXT","positionMs":0,"durationMs":2400000,"progress":0,"lastEngagementMs":4,
  "art":"http://192.168.1.50:8765/api/art/102","artWidth":300,"artHeight":169,"intentUri":"https://www.disneyplus.com/video/abc","browsable":true},
 {"id":103,"package":"com.amazon.amazonvideo.livingroom","app":"Prime Video","title":"Reacher & Friends <S3>",
  "type":"TV_SERIES","watchNextType":"CONTINUE","positionMs":600000,"durationMs":3000000,"progress":20,"lastEngagementMs":3,
  "art":"","intentUri":"","browsable":true}
]}]]

local sampleApps = '{"ok":true,"apps":[{"package":"com.netflix.ninja","label":"Netflix","icon":"http://192.168.1.50:8765/api/icon/com.netflix.ninja"}]}'
-- Answer every outstanding request the way the real bridge would.
local function drain()
	while (#stub.urlRequests > 0) do
		local r = stub.urlRequests[1]
		if (r.url:find('/api/continue', 1, true)) then stub.respond(200, sampleContinue)
		elseif (r.url:find('/api/apps', 1, true)) then stub.respond(200, sampleApps)
		else stub.respond(200, '{"ok":true,"message":"launched"}') end
	end
end

ReceivedFromProxy(5001, 'GetContinue', { NAVID = 'nav1', SEQ = '7', ROOMID = '12',
	ARGS = '<params><param name="screenId">ContinueScreen</param><param name="tabId">Continue</param></params>' })
local req = stub.urlRequests[#stub.urlRequests]
find(req.url, '/api/continue?limit=40&types=CONTINUE,NEXT,NEW', 'continue request url')
eq(req.headers['X-Api-Key'], 'ABC123', 'continue request carries api key')
stub.respond(200, sampleContinue)
local msg = stub.proxyMessages[#stub.proxyMessages]
eq(msg.command, 'DATA_RECEIVED', 'list returned via DATA_RECEIVED')
eq(msg.params.NAVID, 'nav1', 'navid echoed')
eq(msg.params.SEQ, '7', 'seq echoed')
local xml = msg.params.DATA
find(xml, '<List>', 'list xml root')
find(xml, '<title>Continue Watching</title><isHeader>true</isHeader>', 'continue header')
find(xml, '<title>Up Next</title><isHeader>true</isHeader>', 'next header')
find(xml, '<id>101</id>', 'item id')
find(xml, '<title>Severance</title>', 'item title')
find(xml, 'Netflix \194\183 S2 E4 \194\183 Hide and Seek \194\183 36% watched', 'item subtitle')
find(xml, '<duration>35m left</duration>', 'remaining time')
find(xml, '<image_list width="200" height="300">http://192.168.1.50:8765/api/art/101</image_list>', 'poster image')
find(xml, '<default_action>LaunchItem</default_action>', 'default action')
find(xml, '<title>Reacher &amp; Friends &lt;S3&gt;</title>', 'title xml-escaped')
check(not xml:find('api/art/103', 1, true), 'no image tag when art empty')
-- order: Severance (CONTINUE) before Reacher (CONTINUE), and Andor under Up Next after both
local p1, p2, p3 = xml:find('Severance', 1, true), xml:find('Reacher', 1, true), xml:find('Andor', 1, true)
check(p1 < p2 and p2 < p3, 'grouping order')
eq(#Bridge.items, 3, 'items cached')
check(Bridge.itemsById['101'] ~= nil, 'items indexed by id')

------------------------------------------------------------------ launch item
local before = #stub.deviceMessages
ReceivedFromProxy(5001, 'LaunchItem', { NAVID = 'nav1', SEQ = '8', ROOMID = '12',
	ARGS = '<params><param name="id">101</param><param name="title">Severance</param></params>' })
local sel = stub.deviceMessages[before + 1]
check(sel and sel.device == 12 and sel.command == 'SELECT_VIDEO_DEVICE' and sel.params.deviceid == stub.proxyDeviceId, 'room selects our video device')
eq(stub.wol[#stub.wol], '00044baabbcc', 'WOL sent')
local wakeReq, launchReq
for _, r in ipairs(stub.urlRequests) do
	if (r.url:find('/api/wake', 1, true)) then wakeReq = r end
	if (r.url:find('/api/launch', 1, true)) then launchReq = r end
end
check(wakeReq ~= nil, 'wake request sent')
check(launchReq ~= nil and launchReq.method == 'POST', 'launch request posted')
eq(launchReq and launchReq.data, '{"id":101}', 'launch body carries row id')
eq(launchReq and launchReq.headers['Content-Type'], 'application/json', 'launch content type')
local reply = stub.proxyMessages[#stub.proxyMessages]
eq(reply.command, 'DATA_RECEIVED', 'launch acknowledged')
eq(reply.params.DATA, '<NextScreen>#nowplaying</NextScreen>', 'navigator moves to now playing')
eq(stub.variables['LAST_LAUNCHED_TITLE'], 'Severance', 'last title variable')
eq(stub.variables['LAST_LAUNCHED_APP'], 'Netflix', 'last app variable')
check(stub.events[#stub.events] == 'Item Launched', 'Item Launched event')
local sawMedia, sawQueue, sawDash = false, false, false
for _, m in ipairs(stub.proxyMessages) do
	if (m.command == 'UPDATE_MEDIA_INFO' and m.params.TITLE == 'Severance') then sawMedia = true end
	if (m.command == 'SEND_EVENT' and m.params.NAME == 'QueueChanged') then sawQueue = true end
	if (m.command == 'SEND_EVENT' and m.params.NAME == 'DashboardChanged') then sawDash = true end
end
check(sawMedia and sawQueue and sawDash, 'now playing updated')
drain()

-- launch delay path
Properties['Launch Delay (ms)'] = '1500'
ReceivedFromProxy(5001, 'LaunchItem', { NAVID = 'nav1', SEQ = '9', ROOMID = '12', ARGS = '<params><param name="id">102</param></params>' })
local pendingLaunch = false
for _, r in ipairs(stub.urlRequests) do if (r.url:find('/api/launch', 1, true)) then pendingLaunch = true end end
check(not pendingLaunch, 'launch deferred while delay timer runs')
check(Timer.launch ~= nil, 'launch timer armed')
stub.fireTimers()
pendingLaunch = false
for _, r in ipairs(stub.urlRequests) do if (r.url:find('/api/launch', 1, true)) then pendingLaunch = true end end
check(pendingLaunch, 'launch sent after delay')
drain()
Properties['Launch Delay (ms)'] = '0'

------------------------------------------------------------------ apps
ReceivedFromProxy(5001, 'GetApps', { NAVID = 'nav1', SEQ = '10', ROOMID = '12', ARGS = '' })
stub.respond(200, sampleApps)
local appsXml = stub.proxyMessages[#stub.proxyMessages].params.DATA
find(appsXml, '<id>com.netflix.ninja</id>', 'app id')
find(appsXml, '<default_action>LaunchApp</default_action>', 'app action')
ReceivedFromProxy(5001, 'LaunchApp', { NAVID = 'nav1', SEQ = '11', ROOMID = '12', ARGS = '<params><param name="id">com.netflix.ninja</param></params>' })
local lastPost
for _, r in ipairs(stub.urlRequests) do if (r.method == 'POST' and r.url:find('/api/launch', 1, true)) then lastPost = r end end
eq(lastPost and lastPost.data, '{"package":"com.netflix.ninja"}', 'app launch body')
drain()

------------------------------------------------------------------ favorites
ReceivedFromProxy(5001, 'FavoriteToRoom', { NAVID = 'nav1', SEQ = '12', ROOMID = '12',
	ARGS = '<params><param name="screenId">ContinueScreen</param><param name="id">101</param></params>' })
local favXml = stub.proxyMessages[#stub.proxyMessages].params.DATA
find(favXml, '<FavoriteResponse><Title>Severance</Title>', 'favorite response title')
local favId = favXml:match('<favoriteId>(.-)</favoriteId>')
check(favId ~= nil, 'favorite id present')
check(PersistData.favorites[favId].intentUri == 'intent://www.netflix.com/title/81233755#Intent;scheme=https;end', 'favorite stores deep link')
-- the row disappears from Watch Next; the favorite must still launch
Bridge.items = {}
Bridge.itemsById = {}
ReceivedFromProxy(5001, 'jumpToFavorite', { ROOMID = '12', ARGS = '<params><param name="id">' .. favId .. '</param></params>' })
lastPost = nil
for _, r in ipairs(stub.urlRequests) do if (r.method == 'POST' and r.url:find('/api/launch', 1, true)) then lastPost = r end end
find(lastPost and lastPost.data or '', '"intentUri":"intent://www.netflix.com/title/81233755', 'favorite launches by deep link')
drain()

------------------------------------------------------------------ transport forwarding
stub.boundProvider[1001] = 4242
ShieldDeviceId = nil
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'PAUSE', { ROOMID = '12', NAVID = 'nav1' })
local fwd = stub.deviceMessages[#stub.deviceMessages]
check(#stub.deviceMessages == before + 1 and fwd.device == 4242 and fwd.command == 'PAUSE', 'PAUSE forwarded to bound Shield driver')
check(fwd.params.NAVID == nil, 'navigator params stripped when forwarding')
ReceivedFromProxy(5001, 'START_UP', { BEGIN = 'true' })
check(stub.deviceMessages[#stub.deviceMessages].command == 'START_UP', 'held keys forwarded')
Properties['Forward Remote Commands'] = 'Off'
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'PLAY', {})
eq(#stub.deviceMessages, before, 'forwarding can be disabled')
Properties['Forward Remote Commands'] = 'To device on Video In'
OnBindingChanged(1001, 'HDMI', false, 4242, 2001)
eq(ShieldDeviceId, nil, 'unbinding clears cached device')
OnBindingChanged(1001, 'HDMI', true, 4343, 2001)
eq(ShieldDeviceId, 4343, 'binding caches device id')

------------------------------------------------------------------ bridge offline
-- repopulate the cache (the favorites test emptied it) so the offline fallback has data
ReceivedFromProxy(5001, 'GetContinue', { NAVID = 'nav2', SEQ = '19', ROOMID = '12' })
drain()
ReceivedFromProxy(5001, 'GetContinue', { NAVID = 'nav2', SEQ = '20', ROOMID = '12' })
stub.respond(0, '', 'connection refused')
local off = stub.proxyMessages[#stub.proxyMessages]
eq(off.params.ERROR, nil, 'cached list shown instead of error when cache exists')
find(off.params.DATA, 'Bridge offline, showing last known list', 'offline notice header')
eq(Bridge.online, false, 'bridge marked offline')
check(stub.events[#stub.events] == 'Bridge Offline', 'Bridge Offline event')
Bridge.items = {}
ReceivedFromProxy(5001, 'GetContinue', { NAVID = 'nav2', SEQ = '21', ROOMID = '12' })
stub.respond(0, '', 'connection refused')
off = stub.proxyMessages[#stub.proxyMessages]
find(off.params.ERROR or '', 'Shield Bridge unreachable', 'error surfaced when no cache')

------------------------------------------------------------------ programming
ExecuteCommand('Resume Latest', { Room = '12' })
stub.respond(200, sampleContinue)
lastPost = nil
for _, r in ipairs(stub.urlRequests) do if (r.method == 'POST' and r.url:find('/api/launch', 1, true)) then lastPost = r end end
eq(lastPost and lastPost.data, '{"id":101}', 'Resume Latest picks newest CONTINUE row')
drain()
ExecuteCommand('LUA_ACTION', { ACTION = 'Launch URL', URL = 'https://www.youtube.com/watch?v=abc' })
lastPost = nil
for _, r in ipairs(stub.urlRequests) do if (r.method == 'POST' and r.url:find('/api/launch', 1, true)) then lastPost = r end end
eq(lastPost and lastPost.data, '{"url":"https://www.youtube.com/watch?v=abc"}', 'Launch URL body')
drain()
local sel1 = ContinueSelect()
check(#sel1 == 3 and sel1[1].value == '101' and sel1[1].text:find('Severance', 1, true), 'custom select lists items')
local sel2 = AppSelect()
check(#sel2 == 1 and sel2[1].value == 'com.netflix.ninja', 'custom select lists apps')

------------------------------------------------------------------ rows property
Properties['Rows'] = 'Continue Watching only'
eq(RowTypesParam(), 'CONTINUE', 'rows: continue only')
Properties['Rows'] = 'Everything'
eq(RowTypesParam(), '', 'rows: everything')

------------------------------------------------------------------ unknown command still answers navigator
before = #stub.proxyMessages
ReceivedFromProxy(5001, 'SomethingNew', { NAVID = 'nav1', SEQ = '99' })
eq(stub.proxyMessages[#stub.proxyMessages].params.SEQ, '99', 'unknown nav command gets an empty reply')

print(string.format('%d passed, %d failed', passed, failed))
if (failed > 0) then os.exit(1) end
