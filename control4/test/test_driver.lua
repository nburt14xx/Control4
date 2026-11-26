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
	['Select Room Source'] = 'Select Shield Bridge',
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
PersistData.powerSafeApplied = true

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

------------------------------------------------------------------ launch fallback to package on failure
ReceivedFromProxy(5001, 'GetContinue', { NAVID = 'navF', SEQ = '30', ROOMID = '12' })
stub.respond(200, sampleContinue)
ReceivedFromProxy(5001, 'LaunchItem', { NAVID = 'navF', SEQ = '31', ROOMID = '12', ARGS = '<params><param name="id">103</param></params>' })
local launchBodies, launchUrls, guard = {}, {}, 0
while (#stub.urlRequests > 0 and guard < 60) do
	guard = guard + 1
	local r = stub.urlRequests[1]
	if (r.url:find('/api/launch', 1, true)) then
		table.insert(launchBodies, r.data or '')
		table.insert(launchUrls, r.url)
		if ((r.data or ''):find('\"id\"', 1, true)) then
			stub.respond(400, '{"ok":false,"message":"no app can handle resume"}')
		else
			stub.respond(200, '{"ok":true}')
		end
	elseif (r.url:find('/api/continue', 1, true)) then
		stub.respond(200, sampleContinue)
	else
		stub.respond(200, '{"ok":true}')
	end
end
local sawId, sawPkg, sawQuery = false, false, false
for _, b in ipairs(launchBodies) do
	if (b:find('\"id\":103', 1, true)) then sawId = true end
	if (b:find('\"package\":\"com.amazon.amazonvideo.livingroom\"', 1, true)) then sawPkg = true end
end
for _, u in ipairs(launchUrls) do
	if (u:find('/api/launch?id=103', 1, true)) then sawQuery = true end
end
check(sawId, 'resume attempted by id first')
check(sawQuery, 'launch id is also carried in the query string')
check(sawPkg, 'falls back to opening the app when the resume link is refused')

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

------------------------------------------------------------------ relay to the Shield Control Device
-- nothing chosen: keys go nowhere and nothing is sent
Properties['Shield Control Device'] = ''
Properties['Shield Control Device ID'] = ''
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'PAUSE', { ROOMID = '12', NAVID = 'nav1' })
eq(#stub.deviceMessages, before, 'no relay when no control device is chosen')
-- chosen through the picker; it can be in any room, no binding involved
Properties['Shield Control Device'] = '4242'
ReceivedFromProxy(5001, 'PAUSE', { ROOMID = '12', NAVID = 'nav1' })
local fwd = stub.deviceMessages[#stub.deviceMessages]
check(#stub.deviceMessages == before + 1 and fwd.device == 4242 and fwd.command == 'PAUSE', 'PAUSE relayed to the chosen Shield driver')
check(fwd.params.NAVID == nil, 'navigator params stripped when relaying')
ReceivedFromProxy(5001, 'START_UP', { BEGIN = 'true' })
check(stub.deviceMessages[#stub.deviceMessages].command == 'START_UP', 'held keys relayed')
ReceivedFromProxy(5001, 'SCAN_FWD', {})
check(stub.deviceMessages[#stub.deviceMessages].command == 'SCAN_FWD', 'fast forward relayed')
-- the typed ID overrides the picker
Properties['Shield Control Device ID'] = '5151'
ReceivedFromProxy(5001, 'PLAY', {})
eq(stub.deviceMessages[#stub.deviceMessages].device, 5151, 'typed device ID overrides the picker')
Properties['Shield Control Device ID'] = ''
-- never relay to ourselves
Properties['Shield Control Device'] = tostring(stub.proxyDeviceId)
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'PLAY', {})
eq(#stub.deviceMessages, before, 'refuses to relay to itself')
Properties['Shield Control Device'] = '4242'
Properties['Forward Remote Commands'] = 'Off'
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'PLAY', {})
eq(#stub.deviceMessages, before, 'relaying can be disabled')
Properties['Forward Remote Commands'] = 'To device on Video In'   -- legacy value still means on
ReceivedFromProxy(5001, 'PLAY', {})
eq(#stub.deviceMessages, before + 1, 'legacy setting value still relays')
Properties['Forward Remote Commands'] = 'On'

------------------------------------------------------------------ Remote tab
ReceivedFromProxy(5001, 'GetRemote', { NAVID = 'navR', SEQ = '60' })
local rx = stub.proxyMessages[#stub.proxyMessages].params.DATA
find(rx, '<id>UP</id><title>Up</title>', 'remote lists Up')
find(rx, '<id>SCAN_REV</id><title>Rewind</title>', 'remote lists Rewind')
find(rx, 'icons/nav_ff/nav_ff_140.png', 'remote keys carry icons')
find(rx, '<default_action>RemoteKey</default_action>', 'remote keys are tappable')
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'RemoteKey', { NAVID = 'navR', SEQ = '61', ARGS = '<params><param name="id">ENTER</param></params>' })
fwd = stub.deviceMessages[#stub.deviceMessages]
check(#stub.deviceMessages == before + 1 and fwd.device == 4242 and fwd.command == 'ENTER', 'tapping OK relays ENTER')
eq(stub.proxyMessages[#stub.proxyMessages].params.DATA, '', 'remote stays on screen after a press')
-- Home goes through the bridge app, not the control device
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'RemoteKey', { NAVID = 'navR', SEQ = '62', ARGS = '<params><param name="id">HOME</param></params>' })
eq(#stub.deviceMessages, before, 'Home is not relayed to the control device')
local hreq
for _, r in ipairs(stub.urlRequests) do if (r.url:find('category.HOME', 1, true)) then hreq = r end end
check(hreq ~= nil, 'Home asks the bridge app for the launcher')
drain()
-- unknown key ids are ignored
before = #stub.deviceMessages
ReceivedFromProxy(5001, 'RemoteKey', { NAVID = 'navR', SEQ = '63', ARGS = '<params><param name="id">SELF_DESTRUCT</param></params>' })
eq(#stub.deviceMessages, before, 'unknown remote key ignored')
Properties['Shield Control Device'] = ''
ReceivedFromProxy(5001, 'GetRemote', { NAVID = 'navR', SEQ = '64' })
find(stub.proxyMessages[#stub.proxyMessages].params.DATA, 'Set Shield Control Device ID in Composer', 'remote explains when no control device is set')
Properties['Shield Control Device'] = '4242'

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

------------------------------------------------------------------ room source selection
local function selectsSent()
	local n = 0
	for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then n = n + 1 end end
	return n
end
local function lastSelect()
	for i = #stub.deviceMessages, 1, -1 do
		if (stub.deviceMessages[i].command == 'SELECT_VIDEO_DEVICE') then return stub.deviceMessages[i] end
	end
end
-- Never (default): no room command at all
Properties['Select Room Source'] = 'Never'
stub.roomDevice[12] = 555
local n0 = selectsSent()
SelectInRoom('12')
eq(selectsSent(), n0, 'Never: no room select')
-- a value from an older version is treated as Never
Properties['Select Room Source'] = 'Select Shield'
SelectInRoom('12')
eq(selectsSent(), n0, 'legacy Select Shield value sends nothing')
-- Select Shield Bridge: selects this source, unless the room is already on it
Properties['Select Room Source'] = 'Select Shield Bridge'
SelectInRoom('12')
eq(selectsSent(), n0 + 1, 'Select Shield Bridge: sends a select')
eq(lastSelect().params.deviceid, stub.proxyDeviceId, 'Select Shield Bridge: targets this driver')
stub.roomDevice[12] = stub.proxyDeviceId
SelectInRoom('12')
eq(selectsSent(), n0 + 1, 'no re-select when the room is already on Shield Bridge')
stub.roomDevice[12] = nil

------------------------------------------------------------------ rows property------------------------------------------------------------------ rows property
Properties['Rows'] = 'Continue Watching only'
eq(RowTypesParam(), 'CONTINUE', 'rows: continue only')
Properties['Rows'] = 'Everything'
eq(RowTypesParam(), '', 'rows: everything')

------------------------------------------------------------------ unknown command still answers navigator
before = #stub.proxyMessages
ReceivedFromProxy(5001, 'SomethingNew', { NAVID = 'nav1', SEQ = '99' })
eq(stub.proxyMessages[#stub.proxyMessages].params.SEQ, '99', 'unknown nav command gets an empty reply')

------------------------------------------------------------------ Home opens the Shield UI with no room command
local selBefore = 0
for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then selBefore = selBefore + 1 end end
ReceivedFromProxy(5001, 'HOME', { NAVID = 'navH', SEQ = '40', ROOMID = '12' })
local homeReq
for _, r in ipairs(stub.urlRequests) do if (r.url:find('/api/launch', 1, true) and r.url:find('category.HOME', 1, true)) then homeReq = r end end
check(homeReq ~= nil, 'Home posts a launcher intent to the bridge')
local selAfter = 0
for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then selAfter = selAfter + 1 end end
eq(selAfter, selBefore, 'Home sends no room select / power command')
drain()

------------------------------------------------------------------ one-time power-safe migration
PersistData.powerSafeApplied = nil
Properties['Select Room Source'] = 'Select Shield Bridge'
Properties['Wake on Select'] = 'On'
OnDriverLateInit()
drain()
eq(Properties['Select Room Source'], 'Never', 'migration forces Select Room Source = Never')
eq(Properties['Wake on Select'], 'Off', 'migration forces Wake on Select = Off')
check(PersistData.powerSafeApplied == true, 'migration marks itself done')
-- runs only once: changing back is respected on the next init
Properties['Select Room Source'] = 'Select Shield'
OnDriverLateInit()
drain()
eq(Properties['Select Room Source'], 'Select Shield', 'migration does not run twice')

------------------------------------------------------------------ search
-- global search: type a query into the SearchScreen, then press Go
ReceivedFromProxy(5001, 'SettingChanged', { ARGS = '<params><param name="ScreenId">SearchScreen</param><param name="PropertyName">SearchQuery</param><param name="Value">the bear</param></params>' })
eq(PersistData.searchQuery, 'the bear', 'search query stored from the text field')
ReceivedFromProxy(5001, 'SettingChanged', { ARGS = '<params><param name="ScreenId">SearchScreen</param><param name="PropertyName">SearchTarget</param><param name="Value">global</param></params>' })
eq(PersistData.searchTarget, 'global', 'search target stored from the combo box')
-- GetSearch returns the stored values so the field persists
ReceivedFromProxy(5001, 'GetSearch', { NAVID = 'navS', SEQ = '50' })
find(stub.proxyMessages[#stub.proxyMessages].params.DATA, '<SearchQuery>the bear</SearchQuery>', 'GetSearch echoes the stored query')
-- Go: fires a global-search intent via the launch endpoint, no room select
local selBefore = 0
for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then selBefore = selBefore + 1 end end
ReceivedFromProxy(5001, 'SearchGo', { NAVID = 'navS', SEQ = '51', ROOMID = '12' })
local sreq
for _, r in ipairs(stub.urlRequests) do if (r.url:find('/api/launch', 1, true) and r.url:find('GLOBAL_SEARCH', 1, true)) then sreq = r end end
check(sreq ~= nil, 'global search posts a GLOBAL_SEARCH intent')
find(sreq and sreq.url or '', 'S.query', 'search intent carries the query extra')
local selAfter = 0
for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then selAfter = selAfter + 1 end end
eq(selAfter, selBefore, 'search sends no room select / power command')
drain()

-- per-app search builds that app's results URL
local nf = BuildSearchTarget('severance', 'netflix')
eq(nf.url, 'https://www.netflix.com/search?q=severance', 'netflix search url')
local yt = BuildSearchTarget('lofi beats', 'youtube')
eq(yt.url, 'https://www.youtube.com/results?search_query=lofi%20beats', 'youtube search url encodes spaces')
local g = BuildSearchTarget('dune part two', 'All apps')
find(g.intentUri, 'action=android.search.action.GLOBAL_SEARCH', 'All apps maps to global search')
find(g.intentUri, 'S.query=dune%20part%20two', 'global search encodes spaces in the intent')
check(BuildSearchTarget('', 'global') == nil, 'empty query yields no target')

-- programming command
ExecuteCommand('Search', { Query = 'andor', Target = 'Netflix' })
local pnf
for _, r in ipairs(stub.urlRequests) do if (r.method == 'POST' and r.url:find('/api/launch', 1, true) and (r.data or ''):find('netflix.com/search', 1, true)) then pnf = r end end
check(pnf ~= nil, 'Search command launches a Netflix search')
drain()

------------------------------------------------------------------ standard remote screen (media_player proxy 5002)
Properties['Shield Control Device'] = '4242'
Properties['Shield Control Device ID'] = ''
Properties['Forward Remote Commands'] = 'On'
local nd = #stub.deviceMessages
ReceivedFromProxy(5002, 'UP', {})
local rk = stub.deviceMessages[#stub.deviceMessages]
check(#stub.deviceMessages == nd + 1 and rk.device == 4242 and rk.command == 'UP', 'remote screen UP relayed to the Shield driver')
ReceivedFromProxy(5002, 'START_SCAN_FWD', {})
eq(stub.deviceMessages[#stub.deviceMessages].command, 'START_SCAN_FWD', 'held fast-forward relayed from the remote screen')
ReceivedFromProxy(5002, 'NUMBER_4', {})
eq(stub.deviceMessages[#stub.deviceMessages].command, 'NUMBER_4', 'number keys relayed from the remote screen')
-- selecting the remote screen sends no room or power command; wake only if enabled
Properties['Wake on Select'] = 'Off'
nd = #stub.deviceMessages
local nw = #stub.wol
ReceivedFromProxy(5002, 'DEVICE_SELECTED', {})
ReceivedFromProxy(5002, 'ON', {})
ReceivedFromProxy(5002, 'OFF', {})
eq(#stub.deviceMessages, nd, 'remote screen selection sends nothing to the room or the Shield driver')
eq(#stub.wol, nw, 'no wake when Wake on Select is off')
Properties['Wake on Select'] = 'On'
ReceivedFromProxy(5002, 'DEVICE_SELECTED', {})
eq(#stub.wol, nw + 1, 'wakes the Shield when Wake on Select is on')
drain()
Properties['Wake on Select'] = 'Off'
-- the remote screen proxy is never a relay target
Properties['Shield Control Device'] = '780'
nd = #stub.deviceMessages
ReceivedFromProxy(5002, 'UP', {})
eq(#stub.deviceMessages, nd, 'refuses to relay to its own remote screen')
Properties['Shield Control Device'] = '4242'
-- unknown remote-screen commands are ignored
nd = #stub.deviceMessages
ReceivedFromProxy(5002, 'GET_COVERART', {})
eq(#stub.deviceMessages, nd, 'unknown remote-screen command ignored')

------------------------------------------------------------------ After Launch: Switch to Remote
Properties['After Launch'] = 'Switch to Remote'
stub.roomDevice[12] = stub.proxyDeviceId   -- room is on the browse screen
Bridge.itemsById = Bridge.itemsById or {}
ReceivedFromProxy(5001, 'LaunchApp', { NAVID = 'navX', SEQ = '90', ROOMID = '12', ARGS = '<params><param name="id">com.netflix.ninja</param></params>' })
local sw
for i = #stub.deviceMessages, 1, -1 do if (stub.deviceMessages[i].command == 'SELECT_VIDEO_DEVICE') then sw = stub.deviceMessages[i] break end end
check(sw and sw.device == 12 and sw.params.deviceid == 780, 'room switched to the remote screen after launch')
eq(stub.proxyMessages[#stub.proxyMessages].params.DATA, '', 'no Now Playing jump when switching to the remote')
drain()
-- already on the remote screen: no second select
stub.roomDevice[12] = 780
local nsel = 0
for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then nsel = nsel + 1 end end
ReceivedFromProxy(5001, 'LaunchApp', { NAVID = 'navX', SEQ = '91', ROOMID = '12', ARGS = '<params><param name="id">com.netflix.ninja</param></params>' })
local nsel2 = 0
for _, m in ipairs(stub.deviceMessages) do if (m.command == 'SELECT_VIDEO_DEVICE') then nsel2 = nsel2 + 1 end end
eq(nsel2, nsel, 'no re-select when the room is already on the remote screen')
drain()
-- launches from programming carry no navigator room: fall back to Now Playing
eq(AfterLaunchScreen(nil), '<NextScreen>#nowplaying</NextScreen>', 'no room id: Now Playing instead of a switch')
Properties['After Launch'] = 'Go to Now Playing'
stub.roomDevice[12] = nil
eq(ProxyIdFor(5001), 777, 'browse screen proxy id from its binding')
eq(ProxyIdFor(5002), 780, 'remote screen proxy id from its binding')

------------------------------------------------------------------ transport bar layout
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navD', SEQ = '95' })
local dash
for i = #stub.proxyMessages, 1, -1 do local m = stub.proxyMessages[i] if (m.command == 'SEND_EVENT' and m.params.NAME == 'DashboardChanged') then dash = m.params.EVTARGS break end end
eq(dash, '<Items>Ok Play Pause SkipFwd Menu DpadOn</Items>', 'transport bar: OK left, Menu right, D-pad toggle last')
Properties['Shield Control Device'] = '4242'
ReceivedFromProxy(5001, 'ENTER', {})
eq(stub.deviceMessages[#stub.deviceMessages].command, 'ENTER', 'transport OK relays ENTER')
ReceivedFromProxy(5001, 'MENU', {})
eq(stub.deviceMessages[#stub.deviceMessages].command, 'MENU', 'transport Menu relays MENU')

------------------------------------------------------------------ transport bar D-pad mode
local function lastDash()
	for i = #stub.proxyMessages, 1, -1 do
		local m = stub.proxyMessages[i]
		if (m.command == 'SEND_EVENT' and m.params.NAME == 'DashboardChanged') then return m.params end
	end
end
local PLAYBACK = '<Items>Ok Play Pause SkipFwd Menu DpadOn</Items>'
local DPAD = '<Items>Back Left Up Ok Down Right DpadOff</Items>'
ReceivedFromProxy(5001, 'DpadMode', { NAVID = 'navA', ROOMID = '14', SEQ = '96' })
local d = lastDash()
eq(d.EVTARGS, DPAD, 'D-pad button swaps the bar to arrows')
eq(d.NAVID, 'navA', 'only the navigator that pressed it changes')
eq(stub.proxyMessages[#stub.proxyMessages].command, 'DATA_RECEIVED', 'D-pad press is answered')
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navA', SEQ = '97' })
eq(lastDash().EVTARGS, DPAD, 'navigator keeps D-pad mode when it asks again')
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navB', SEQ = '98' })
eq(lastDash().EVTARGS, PLAYBACK, 'other navigators stay on playback')
before = #stub.deviceMessages
for _, k in ipairs({ 'LEFT', 'UP', 'DOWN', 'RIGHT', 'CANCEL' }) do ReceivedFromProxy(5001, k, { NAVID = 'navA', ROOMID = '14' }) end
eq(#stub.deviceMessages, before + 5, 'arrow and back buttons relay')
eq(stub.deviceMessages[before + 1].command, 'LEFT', 'left arrow relays LEFT')
eq(stub.deviceMessages[before + 5].command, 'CANCEL', 'back relays CANCEL')
eq(stub.deviceMessages[before + 5].device, 4242, 'arrows go to the Shield Control Device')
ReceivedFromProxy(5001, 'PlaybackMode', { NAVID = 'navA', ROOMID = '14', SEQ = '99' })
eq(lastDash().EVTARGS, PLAYBACK, 'playback button swaps back')
-- a press without a navigator id flips the whole room
ReceivedFromProxy(5001, 'DpadMode', { ROOMID = '14' })
d = lastDash()
check(d.EVTARGS == DPAD and d.NAVID == nil and d.ROOMS == '14', 'D-pad press without NAVID goes to the room')
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navC', SEQ = '100' })
eq(lastDash().EVTARGS, DPAD, 'room-wide D-pad mode answers any navigator')
ReceivedFromProxy(5001, 'PlaybackMode', { NAVID = 'navC', SEQ = '101' })
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navC', SEQ = '102' })
eq(lastDash().EVTARGS, PLAYBACK, 'a navigator can leave room-wide D-pad mode')
-- selecting the source (a broadcast) resets everyone to playback
ReceivedFromProxy(5001, 'DpadMode', { NAVID = 'navA', SEQ = '103' })
ReceivedFromProxy(5001, 'DEVICE_SELECTED', {})
drain()
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navA', SEQ = '104' })
eq(lastDash().EVTARGS, PLAYBACK, 'selecting the source resets D-pad mode')
ReceivedFromProxy(5001, 'DpadMode', { NAVID = 'navA', SEQ = '105' })
ReceivedFromProxy(5001, 'DESTROY_NAVIGATOR', { NAVID = 'navA' })
eq(DashMode['navA'], nil, 'closed navigator forgets its mode')

-- every button the driver asks for exists in driver.xml with an icon group
do
	local fh = assert(io.open('control4/shield_bridge/driver.xml'))
	local xml = fh:read('*a')
	fh:close()
	local dashXml = xml:match('<Dashboard>(.-)</Dashboard>')
	local transports = {}
	for t in dashXml:gmatch('<Transport>(.-)</Transport>') do
		transports[t:match('<Id>(.-)</Id>')] = t
	end
	for _, set in ipairs({ DASH_PLAYBACK, DASH_DPAD }) do
		for id in set:gmatch('%S+') do
			local t = transports[id]
			check(t ~= nil, 'transport ' .. id .. ' is defined in driver.xml')
			local icon = t and t:match('<IconId>(.-)</IconId>')
			if (icon) then
				find(xml, '<IconGroup id="' .. icon .. '">', 'icon group for ' .. id)
				find(xml, 'controller://driver/shield_bridge/icons/' .. icon .. '/' .. icon .. '_70.png', 'icon file path for ' .. id)
				local f = io.open('control4/shield_bridge/icons/' .. icon .. '/' .. icon .. '_70.png', 'rb')
				check(f ~= nil, 'icon file exists for ' .. id)
				if (f) then f:close() end
			end
		end
	end
	for path in xml:gmatch('controller://driver/([^<"]+)') do
		if (not path:find('^shield_bridge/')) then check(false, 'icon path names the installed file: ' .. path) end
	end
end

------------------------------------------------------------------ installed file name
stub.driverFileName = 'shield_bridge.c4z'
eq(DriverAsset('icons/x.png'), 'controller://driver/shield_bridge/icons/x.png', 'asset path from the canonical file name')
eq(CheckDriverFile(), true, 'canonical file name passes')
eq(Properties['Driver File'], 'shield_bridge.c4z', 'Driver File property shows the installed name')
stub.driverFileName = 'shield_bridge (1).c4z'
eq(DriverAsset('icons/x.png'), 'controller://driver/shield_bridge%20(1)/icons/x.png', 'asset path follows a renamed file')
ReceivedFromProxy(5001, 'GetRemote', { NAVID = 'navR', SEQ = '106' })
find(stub.proxyMessages[#stub.proxyMessages].params.DATA, 'controller://driver/shield_bridge%20(1)/icons/nav_up/nav_up_140.png', 'remote tab icons follow the installed name')
eq(CheckDriverFile(), false, 'other file names are flagged')
find(Properties['Driver File'], 'rename to shield_bridge.c4z', 'Driver File property says what to do')
stub.driverFileName = nil
eq(DriverAsset('icons/x.png'), 'controller://driver/shield_bridge/icons/x.png', 'asset path falls back to the canonical name')

------------------------------------------------------------------ live Now Playing (media sessions)
local function respondTo(pat, code, body)
	for i, r in ipairs(stub.urlRequests) do
		if (r.url:find(pat, 1, true)) then
			table.remove(stub.urlRequests, i)
			r.callback(1, body, code, {}, nil)
			return r
		end
	end
	return nil
end
local function lastMedia()
	for i = #stub.proxyMessages, 1, -1 do
		local m = stub.proxyMessages[i]
		if (m.command == 'UPDATE_MEDIA_INFO') then return m.params, i end
	end
end
local function countMedia()
	local n = 0
	for _, m in ipairs(stub.proxyMessages) do if (m.command == 'UPDATE_MEDIA_INFO') then n = n + 1 end end
	return n
end
local function lastEvent(name)
	for i = #stub.proxyMessages, 1, -1 do
		local m = stub.proxyMessages[i]
		if (m.command == 'SEND_EVENT' and m.params.NAME == name) then return m.params end
	end
end
-- the bar sent to one navigator since message index `from`
local function dashFor(navId, from)
	for i = #stub.proxyMessages, (from or 1), -1 do
		local m = stub.proxyMessages[i]
		if (m.command == 'SEND_EVENT' and m.params.NAME == 'DashboardChanged' and m.params.NAVID == navId) then return m.params.EVTARGS end
	end
end
local NP_PLAYING = '{"ok":true,"active":true,"package":"com.netflix.ninja","app":"Netflix","state":"playing",' ..
	'"title":"Hide and Seek","subtitle":"Severance","artist":"","album":"","durationMs":3300000,"positionMs":1200000,' ..
	'"artKey":"ab12","art":"http://192.168.1.50:8765/api/nowplaying/art?v=ab12"}'
drain()
stub.urlRequests = {}
KillTimer('np')
Bridge.selected = {}
Bridge.lastLaunched = { title = 'Severance', subtitle = 'S2 E4', app = 'Netflix', art = 'http://192.168.1.50:8765/api/art/101',
	id = 101, package = 'com.netflix.ninja', launchedAt = os.time() - 600 }
Properties['Now Playing Refresh (s)'] = '5'
ReceivedFromProxy(5001, 'DEVICE_SELECTED', { ROOMID = '14' })
check(Timer.np ~= nil, 'selecting the source starts the Now Playing check')
check(respondTo('/api/nowplaying', 200, NP_PLAYING) ~= nil, 'asks the app what is playing straight away')
local m = lastMedia()
eq(m.TITLE, 'Hide and Seek', 'Now Playing shows the playing title')
eq(m.ALBUM, 'Severance', 'and its show')
eq(m.ARTIST, 'Netflix', 'and the app')
eq(m.IMAGEURL, C4:Base64Encode('http://192.168.1.50:8765/api/nowplaying/art?v=ab12'), 'with the artwork of what is playing')
eq(lastEvent('ProgressChanged').EVTARGS, '<length>3300</length><offset>1200</offset><label>20:00 / 55:00</label>', 'progress bar')
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navP', ROOMID = '14', SEQ = '700' })
eq(lastEvent('DashboardChanged').EVTARGS, '<Items>Ok Pause SkipFwd Menu DpadOn</Items>', 'playing: only Pause shows')
-- the same report again changes nothing
local before = countMedia()
FetchNowPlaying()
respondTo('/api/nowplaying', 200, NP_PLAYING)
eq(countMedia(), before, 'unchanged report sends no update')
-- paused: the bar follows, per navigator
local paused = NP_PLAYING:gsub('"state":"playing"', '"state":"paused"')
local mark = #stub.proxyMessages
FetchNowPlaying()
respondTo('/api/nowplaying', 200, paused)
eq(dashFor('navP', mark + 1), '<Items>Ok Play SkipFwd Menu DpadOn</Items>', 'paused: only Play shows, sent to that navigator')
ReceivedFromProxy(5001, 'DpadMode', { NAVID = 'navP', ROOMID = '14', SEQ = '701' })
mark = #stub.proxyMessages
FetchNowPlaying()
respondTo('/api/nowplaying', 200, NP_PLAYING)
eq(dashFor('navP', mark + 1), '<Items>Back Left Up Ok Down Right DpadOff</Items>', 'a navigator in D-pad mode keeps its arrows when play state changes')
ReceivedFromProxy(5001, 'PlaybackMode', { NAVID = 'navP', ROOMID = '14', SEQ = '702' })
-- no artwork from the app: the launched poster for the same show, else the app icon
FetchNowPlaying()
respondTo('/api/nowplaying', 200, NP_PLAYING:gsub('"art":"[^"]*"', '"art":""'))
eq(lastMedia().IMAGEURL, C4:Base64Encode('http://192.168.1.50:8765/api/art/101'), 'same show as the launch: its poster')
local yt = '{"ok":true,"active":true,"package":"com.google.android.youtube.tv","app":"YouTube","state":"playing",' ..
	'"title":"Cat video","subtitle":"","artist":"Cats Inc","album":"","durationMs":0,"positionMs":0,"artKey":"x","art":""}'
FetchNowPlaying()
respondTo('/api/nowplaying', 200, yt)
m = lastMedia()
eq(m.TITLE, 'Cat video', 'something started with the Shield remote shows too')
eq(m.ALBUM, 'Cats Inc', 'artist fills the second line when there is no subtitle')
eq(m.IMAGEURL, C4:Base64Encode('http://192.168.1.50:8765/api/icon/com.google.android.youtube.tv'), 'no artwork: the app icon')
-- nothing playing, or no permission: back to the last launch
FetchNowPlaying()
respondTo('/api/nowplaying', 200, '{"ok":true,"active":false}')
eq(lastMedia().TITLE, 'Severance', 'nothing playing: last launch')
eq(Bridge.playState, nil, 'no play state when nothing plays')
FetchNowPlaying()
respondTo('/api/nowplaying', 200, NP_PLAYING:gsub('"state":"playing"', '"state":"stopped"'))
eq(lastMedia().TITLE, 'Severance', 'a stopped session does not count')
FetchNowPlaying()
respondTo('/api/nowplaying', 403, '{"ok":false,"error":"notification access not granted; open the Shield Bridge app on the TV"}')
eq(lastMedia().TITLE, 'Severance', 'no notification access: last launch')
find(Bridge.nowPlayingNote or '', 'allow Notification access', 'says how to turn it on')
FetchNowPlaying()
respondTo('/api/nowplaying', 404, '{"ok":false,"error":"unknown path /api/nowplaying"}')
find(Bridge.nowPlayingNote or '', 'update the Shield Bridge app', 'older app: says to update it')
-- right after a launch, the previous app's lingering session does not override it
ReceivedFromProxy(5001, 'LaunchItem', { NAVID = 'navP', SEQ = '703', ROOMID = '14', ARGS = '<params><param name="id">101</param></params>' })
check(Timer.nplaunch1 ~= nil and Timer.nplaunch2 ~= nil, 'checks again soon after a launch')
drain()
Bridge.lastLaunched.package = 'com.netflix.ninja'
FetchNowPlaying()
respondTo('/api/nowplaying', 200, yt)
eq(lastMedia().TITLE, 'Severance', 'old app still reporting right after a launch: launched title kept')
Bridge.lastLaunched.launchedAt = os.time() - LAUNCH_SETTLE_SECS - 1
FetchNowPlaying()
respondTo('/api/nowplaying', 200, yt:gsub('Cat video', 'Dog video'))
eq(lastMedia().TITLE, 'Dog video', 'after the settle time the live report wins')
-- the Now Playing list leads with what is playing
UpdateQueue('navP', '14')
find(lastEvent('QueueChanged').EVTARGS, '<title>Dog video</title>', 'queue shows the live title first')
-- play/pause presses get a quick re-check
KillTimer('npquick')
ReceivedFromProxy(5001, 'PAUSE', { NAVID = 'navP', ROOMID = '14' })
check(Timer.npquick ~= nil, 'pause press re-checks soon')
KillTimer('npquick')
HandleRemoteProxy('PLAY', {})
check(Timer.npquick ~= nil, 'remote screen play press re-checks soon')
-- polling follows selection across both screens
ReceivedFromProxy(5002, 'DEVICE_SELECTED', { ROOMID = '14' })
ReceivedFromProxy(5001, 'DEVICE_DESELECTED', { ROOMID = '14' })
check(Timer.np ~= nil, 'still checking while the remote screen is selected')
ReceivedFromProxy(5002, 'DEVICE_DESELECTED', {})
check(Timer.np == nil, 'stops when neither screen is selected')
stub.urlRequests = {}
ReceivedFromProxy(5001, 'GetDashboard', { NAVID = 'navQ', SEQ = '704' })
check(Timer.npview ~= nil, 'opening Now Playing while not selected checks once')
KillTimer('npview')
Properties['Now Playing Refresh (s)'] = '0'
ReceivedFromProxy(5001, 'DEVICE_SELECTED', { ROOMID = '14' })
check(Timer.np == nil, 'refresh 0: no repeating check')
ReceivedFromProxy(5001, 'DEVICE_DESELECTED', { ROOMID = '14' })
Properties['Now Playing Refresh (s)'] = '5'
stub.urlRequests = {}

print(string.format('%d passed, %d failed', passed, failed))
if (failed > 0) then os.exit(1) end
