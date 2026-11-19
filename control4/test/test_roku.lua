-- Run from the repository root:  lua5.1 control4/test/test_roku.lua
-- Exercises the Roku Bridge driver against a fake C4 runtime. ECP fixtures
-- follow Roku's External Control Protocol XML; search fixtures follow the
-- Streaming Availability API's OpenAPI v4 field names.

package.path = 'control4/test/?.lua;' .. package.path
local stub = require('c4stub')

Properties = {
	['Roku Address'] = '192.168.1.60',
	['Roku Status'] = '',
	['Power Commands'] = 'Off',
	['Select Room Source'] = 'Never',
	['After Launch'] = 'Go to Now Playing',
	['Recent List Size'] = '3',
	['Now Playing Refresh (s)'] = '10',
	['Search API Key'] = 'k-123',
	['Search API Service'] = 'Movie of the Night',
	['Search Country'] = 'us',
	['Search Includes'] = 'Subscription and free',
	['Show Titles Not On Roku'] = 'Yes',
	['Search Status'] = '',
	['Debug Mode'] = 'Off',
}
stub.properties = Properties
dofile('control4/roku_bridge/driver.lua')

local passed, failed = 0, 0
local function check(cond, msg)
	if (cond) then passed = passed + 1 else failed = failed + 1 print('FAIL: ' .. msg) end
end
local function eq(a, b, msg)
	check(a == b, msg .. ' (got ' .. tostring(a) .. ', want ' .. tostring(b) .. ')')
end
local function find(s, pat, msg)
	check(type(s) == 'string' and s:find(pat, 1, true) ~= nil, msg .. ' (missing "' .. pat .. '" in ' .. tostring(s):sub(1, 300) .. ')')
end
local DOT = ' \194\183 '

local function respondTo(pat, code, body, err)
	for i, r in ipairs(stub.urlRequests) do
		if (r.url:find(pat, 1, true)) then
			table.remove(stub.urlRequests, i)
			r.callback(1, body, code, {}, err)
			return r
		end
	end
	return nil
end
local function pending(pat)
	local n = 0
	for _, r in ipairs(stub.urlRequests) do if (r.url:find(pat, 1, true)) then n = n + 1 end end
	return n
end
local function lastReply() return stub.proxyMessages[#stub.proxyMessages].params end
-- answer and return every outstanding request matching pat, oldest first
local function take(pat)
	local got = {}
	while (pending(pat) > 0) do table.insert(got, respondTo(pat, 200, '')) end
	return got
end
local function clear() stub.urlRequests = {} end

local APPS_XML = '<?xml version="1.0" encoding="UTF-8" ?><apps>' ..
	'<app id="12" type="appl" version="5.1">Netflix</app>' ..
	'<app id="2285" type="appl" version="6.1">Hulu</app>' ..
	'<app id="291097" type="appl" version="1.2">Disney Plus</app>' ..
	'<app id="61322" type="appl" version="55.0">Max</app>' ..
	'<app id="2595" type="appl" version="3.0">Crunchyroll</app>' ..
	'<app id="13842" type="appl" version="9.0">Fandango at Home</app>' ..
	'<app id="837" type="appl" version="2.0">YouTube</app>' ..
	'<app id="99999" type="appl" version="1.0">Tom &amp; Jerry TV</app>' ..
	'<app id="31012" type="menu" version="2.0">Vudu Movie &amp; TV Store</app>' ..
	'</apps>'

------------------------------------------------------------------ init + channels
OnDriverLateInit()
eq(Properties['Driver Version'], DRIVER_VERSION, 'version written')
local q = respondTo('/query/apps', 200, APPS_XML)
eq(q and q.url, 'http://192.168.1.60:8060/query/apps', 'ECP base adds port 8060')
eq(#Roku.apps, 8, 'channels parsed, menu entries skipped')
eq(Roku.appsById['99999'].name, 'Tom & Jerry TV', 'channel names XML-decoded')
eq(Roku.apps[1].name, 'Crunchyroll', 'channels sorted by name')
eq(Roku.online, true, 'Roku marked online')
eq(Properties['Roku Status'], 'Online', 'status property set')

ReceivedFromProxy(5001, 'GetChannels', { NAVID = 'n1', SEQ = '1' })
respondTo('/query/apps', 200, APPS_XML)
local data = lastReply().DATA
find(data, '<id>12</id><title>Netflix</title>', 'channel listed')
find(data, 'http://192.168.1.60:8060/query/icon/12', 'channel icon served by the Roku')
find(data, '<title>Tom &amp; Jerry TV</title>', 'channel name re-encoded for XML')
find(data, '<default_action>LaunchChannel</default_action>', 'channel is tappable')

ReceivedFromProxy(5001, 'LaunchChannel', { NAVID = 'n1', SEQ = '2', ROOMID = '12', ARGS = '<params><param name="id">837</param></params>' })
local l = respondTo('/launch/', 200, '')
check(l and l.method == 'POST' and l.url == 'http://192.168.1.60:8060/launch/837', 'channel launch is a POST with no content id')
eq(lastReply().DATA, '<NextScreen>#nowplaying</NextScreen>', 'moves to now playing')
eq(stub.variables['LAST_LAUNCHED_TITLE'], 'YouTube', 'now playing shows the channel')
eq(#stub.deviceMessages, 0, 'no room command on launch by default')

------------------------------------------------------------------ remote keys
clear()
ReceivedFromProxy(5001, 'UP', {})
eq(take('/keypress/')[1].url, 'http://192.168.1.60:8060/keypress/Up', 'UP -> Up')
ReceivedFromProxy(5001, 'ENTER', {})
find(take('/keypress/')[1].url, '/keypress/Select', 'ENTER -> Select')
ReceivedFromProxy(5001, 'CANCEL', {})
find(take('/keypress/')[1].url, '/keypress/Back', 'CANCEL -> Back')
ReceivedFromProxy(5001, 'SCAN_FWD', {})
find(take('/keypress/')[1].url, '/keypress/Fwd', 'SCAN_FWD -> Fwd')
ReceivedFromProxy(5001, 'SKIP_REV', {})
find(take('/keypress/')[1].url, '/keypress/InstantReplay', 'SKIP_REV -> InstantReplay')
ReceivedFromProxy(5001, 'NUMBER_7', {})
find(take('/keypress/')[1].url, '/keypress/Lit_7', 'digits typed as literals')
-- held keys: press on START, release on STOP
ReceivedFromProxy(5001, 'START_LEFT', {})
find(take('/keydown/')[1].url, '/keydown/Left', 'START_LEFT -> keydown')
ReceivedFromProxy(5001, 'STOP_LEFT', {})
find(take('/keyup/')[1].url, '/keyup/Left', 'STOP_LEFT -> keyup')
ReceivedFromProxy(5001, 'PULSE_DOWN', {})
find(take('/keypress/')[1].url, '/keypress/Down', 'PULSE_DOWN -> keypress')
-- on-screen buttons get a reply so Navigator does not wait
ReceivedFromProxy(5001, 'HOME', { NAVID = 'n1', SEQ = '3' })
find(take('/keypress/')[1].url, '/keypress/Home', 'HOME -> Home')
eq(lastReply().SEQ, '3', 'on-screen key press acknowledged')
ReceivedFromProxy(5001, 'NOT_A_KEY', {})
eq(#stub.urlRequests, 0, 'unknown command sends nothing')

-- Play and Pause: Roku only toggles, so the driver checks the state first
local function player(state) return '<player error="false" state="' .. state .. '"><plugin id="12" name="Netflix"/><position>60000 ms</position><duration>3600000 ms</duration></player>' end
ReceivedFromProxy(5001, 'PAUSE', {})
respondTo('/query/media-player', 200, player('play'))
eq(#take('/keypress/Play'), 1, 'PAUSE while playing toggles')
ReceivedFromProxy(5001, 'PAUSE', {})
respondTo('/query/media-player', 200, player('pause'))
eq(pending('/keypress/'), 0, 'PAUSE while already paused does nothing')
ReceivedFromProxy(5001, 'PLAY', {})
respondTo('/query/media-player', 200, player('play'))
eq(pending('/keypress/'), 0, 'PLAY while already playing does nothing')
ReceivedFromProxy(5001, 'PLAY', {})
respondTo('/query/media-player', 200, player('pause'))
eq(#take('/keypress/Play'), 1, 'PLAY while paused toggles')
ReceivedFromProxy(5001, 'PLAY', {})
respondTo('/query/media-player', 200, '<player error="false" state="close"/>')
eq(#take('/keypress/Play'), 1, 'unknown player state falls back to a toggle')

-- Remote tab
ReceivedFromProxy(5001, 'GetRemote', { NAVID = 'n1', SEQ = '4' })
data = lastReply().DATA
find(data, '<id>SCAN_REV</id><title>Rewind</title>', 'remote lists Rewind')
find(data, 'controller://driver/roku_bridge/icons/nav_ff/nav_ff_140.png', 'remote icons use this driver')
ReceivedFromProxy(5001, 'RemoteKey', { NAVID = 'n1', SEQ = '5', ARGS = '<params><param name="id">ENTER</param></params>' })
find(take('/keypress/')[1].url, '/keypress/Select', 'tapping OK sends Select')
eq(lastReply().DATA, '', 'remote stays on screen')
ReceivedFromProxy(5001, 'RemoteKey', { NAVID = 'n1', SEQ = '6', ARGS = '<params><param name="id">PowerOff</param></params>' })
eq(#stub.urlRequests, 0, 'keys not on the remote list are ignored')

-- typing text: one key at a time, in order
ExecuteCommand('Send Text', { Text = 'a b' })
find(respondTo('/keypress/', 200, '').url, '/keypress/Lit_a', 'first character')
find(respondTo('/keypress/', 200, '').url, '/keypress/Lit_%20', 'space is URL-encoded')
find(respondTo('/keypress/', 200, '').url, '/keypress/Lit_b', 'third character')
eq(#stub.urlRequests, 0, 'text finished')

------------------------------------------------------------------ search
local function svc(id, name)
	return '{"id":"' .. id .. '","name":"' .. name .. '","homePage":"x","themeColorCode":"#000","imageSet":{"lightThemeImage":"x","darkThemeImage":"x","whiteImage":"x"}}'
end
local function opt(service, otype, link, extra)
	return '{"service":' .. service .. ',"type":"' .. otype .. '","link":"' .. link .. '","audios":[],"subtitles":[],"expiresSoon":false,"availableSince":1' .. (extra or '') .. '}'
end
local function show(id, stype, title, yearField, options)
	return '{"itemType":"show","showType":"' .. stype .. '","id":"' .. id .. '","title":"' .. title .. '","' .. yearField .. '":2024,' ..
		'"imageSet":{"verticalPoster":{"w240":"https://cdn.example/' .. id .. '/240.jpg","w360":"x"},"horizontalPoster":{"w360":"h"}},' ..
		'"streamingOptions":' .. options .. '}'
end
local SEARCH_JSON = '[' ..
	show('2001', 'series', 'Wednesday', 'firstAirYear', '{"us":[' ..
		opt(svc('netflix', 'Netflix'), 'subscription', 'https://www.netflix.com/title/81231974/', ',"quality":"uhd"') .. ']}') .. ',' ..
	show('2002', 'series', 'The Bear', 'firstAirYear', '{"us":[' ..
		opt(svc('hulu', 'Hulu'), 'subscription', 'https://www.hulu.com/series/the-bear-05eb6a8e-90ed-4947-8c0b-e6536cbddd5f', ',"quality":"uhd"') .. ',' ..
		opt(svc('disney', 'Disney+'), 'subscription', 'https://www.disneyplus.com/browse/entity-081d1bd1-8a3c-4e0d-9b5f-1c2d3e4f5a6b', ',"quality":"uhd"') .. ']}') .. ',' ..
	show('2003', 'series', 'Severance', 'firstAirYear', '{"us":[' ..
		opt(svc('apple', 'Apple TV'), 'subscription', 'https://tv.apple.com/us/show/severance/umc.cmc.1srk2goyh2q2zdxcx605w8vtx', ',"quality":"uhd"') .. ']}') .. ',' ..
	show('2004', 'movie', 'Dune', 'releaseYear', '{"us":[' ..
		opt(svc('hbo', 'Max'), 'subscription', 'https://play.max.com/movie/e7dc7b3a-a494-4ef1-8107-f4308aa6bbf7', ',"quality":"uhd"') .. ']}') .. ',' ..
	show('2005', 'series', 'Frieren', 'firstAirYear', '{"us":[' ..
		opt(svc('crunchyroll', 'Crunchyroll'), 'subscription', 'https://www.crunchyroll.com/series/GG5H5XQX4/frieren', '') .. ']}') .. ',' ..
	show('2006', 'movie', 'Obscure', 'releaseYear', '{"us":[' ..
		opt(svc('zzz', 'ZedStream'), 'subscription', 'https://zed.example/watch/77', '') .. ']}') .. ',' ..
	show('2007', 'series', 'Elsewhere', 'firstAirYear', '{"gb":[' ..
		opt(svc('netflix', 'Netflix'), 'subscription', 'https://www.netflix.com/title/1/', '') .. ']}') ..
	']'
check(#(JSON.decode(SEARCH_JSON) or {}) == 7, 'search fixture decodes')

local function search(navId, seq, query, filter)
	ReceivedFromProxy(5001, 'SearchResults', { NAVID = navId, SEQ = seq, ROOMID = '12',
		ARGS = '<params><param name="search">' .. query .. '</param>' .. (filter and ('<param name="search_filter">' .. filter .. '</param>') or '') .. '</params>' })
end

clear()
Roku.appsAt = 0   -- stale channel list: refreshed before searching
search('n1', '10', 'wednesday')
check(respondTo('/query/apps', 200, APPS_XML) ~= nil, 'channels refreshed before searching')
local api = stub.urlRequests[#stub.urlRequests]
eq(api.url, 'https://api.movieofthenight.com/v4/shows/search/title?title=wednesday&country=us&series_granularity=show&output_language=en', 'search scoped to the country')
eq(api.headers['X-API-Key'], 'k-123', 'API key sent')
respondTo('movieofthenight', 200, SEARCH_JSON)
data = lastReply().DATA
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'Netflix</subtitle>', 'installed channel named')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'Hulu, Disney Plus</subtitle>', 'Disney+ matched to the Roku channel named Disney Plus')
find(data, '<subtitle>2024' .. DOT .. 'Movie' .. DOT .. 'Max</subtitle>', 'hbo service matched to the Max channel')
find(data, '<title>On channels you can add</title><isHeader>true</isHeader>', 'heading for installable channels')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'On Apple TV (not installed)</subtitle>', 'uninstalled channel explained')
find(data, '<title>Not available on this Roku</title><isHeader>true</isHeader>', 'heading for unknown services')
find(data, '<subtitle>2024' .. DOT .. 'Movie' .. DOT .. 'On ZedStream</subtitle>', 'unknown service named')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'Not streaming in US</subtitle>', 'other-country title marked')
find(data, '<image_list width="240" height="360">https://cdn.example/2001/240.jpg</image_list>', 'poster attached')
check(data:find('Wednesday', 1, true) < data:find('Severance', 1, true), 'playable results first')
find(Properties['Search Status'], 'OK: 7 results for "wednesday" in US', 'status reports the count')

-- repeat is served from cache, and a fresh channel list is not re-read
search('n1', '11', 'wednesday')
eq(#stub.urlRequests, 0, 'repeat search needs no network calls')

------------------------------------------------------------------ content ids per service
eq(RokuContentId('netflix', 'https://www.netflix.com/title/81231974/'), '81231974', 'Netflix: title number')
eq(RokuContentId('hulu', 'https://www.hulu.com/series/the-bear-05eb6a8e-90ed-4947-8c0b-e6536cbddd5f'), '05eb6a8e-90ed-4947-8c0b-e6536cbddd5f', 'Hulu: trailing UUID without the slug')
eq(RokuContentId('disney', 'https://www.disneyplus.com/browse/entity-081d1bd1-8a3c-4e0d-9b5f-1c2d3e4f5a6b'), '081d1bd1-8a3c-4e0d-9b5f-1c2d3e4f5a6b', 'Disney+: entity id')
eq(RokuContentId('hbo', 'https://play.max.com/movie/e7dc7b3a-a494-4ef1-8107-f4308aa6bbf7?x=1'), 'e7dc7b3a-a494-4ef1-8107-f4308aa6bbf7', 'Max: id after /movie/, query dropped')
eq(RokuContentId('apple', 'https://tv.apple.com/us/show/severance/umc.cmc.1srk2goyh2q2zdxcx605w8vtx'), 'umc.cmc.1srk2goyh2q2zdxcx605w8vtx', 'Apple TV: umc id')
eq(RokuContentId('crunchyroll', 'https://www.crunchyroll.com/series/GG5H5XQX4/frieren'), 'GG5H5XQX4', 'Crunchyroll: series id, not the slug')
eq(RokuContentId('prime', 'https://www.amazon.com/gp/video/detail/B0CX1Y2Z3A/ref=atv_dp'), 'B0CX1Y2Z3A', 'Prime: ASIN')
eq(RokuContentId('paramount', 'https://www.paramountplus.com/shows/halo/'), 'halo', 'unlisted service: last path segment')

------------------------------------------------------------------ tap: one channel plays at once
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'n1', SEQ = '12', ROOMID = '12', ARGS = '<params><param name="id">2001</param></params>' })
l = respondTo('/launch/', 200, '')
eq(l.url, 'http://192.168.1.60:8060/launch/12?contentId=81231974&mediaType=series', 'Netflix deep link')
eq(l.method, 'POST', 'launch is a POST')
eq(lastReply().DATA, '<NextScreen>#nowplaying</NextScreen>', 'moves to now playing')
eq(stub.variables['LAST_LAUNCHED_TITLE'], 'Wednesday', 'now playing title')
eq(RecentList()[1].title, 'Wednesday', 'added to recent')

ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'n1', SEQ = '13', ROOMID = '12', ARGS = '<params><param name="id">2004</param></params>' })
eq(respondTo('/launch/', 200, '').url, 'http://192.168.1.60:8060/launch/61322?contentId=e7dc7b3a-a494-4ef1-8107-f4308aa6bbf7&mediaType=movie', 'Max movie deep link')

------------------------------------------------------------------ two channels: where to watch
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'n1', SEQ = '14', ROOMID = '12', ARGS = '<params><param name="id">2002</param></params>' })
eq(lastReply().DATA, '<NextScreen>WhereToWatchScreen</NextScreen>', 'multi-channel title opens the chooser')
eq(pending('/launch/'), 0, 'nothing launched yet')
ReceivedFromProxy(5001, 'GetWhereToWatch', { NAVID = 'n1', SEQ = '15', ARGS = '' })
data = lastReply().DATA
find(data, '<id>2002|1</id><title>Hulu</title><subtitle>Included with subscription' .. DOT .. '4K</subtitle>', 'Hulu option')
find(data, '<id>2002|2</id><title>Disney Plus</title>', 'Disney option uses the Roku channel name')
find(data, 'query/icon/2285', 'channel icon shown per option')
ReceivedFromProxy(5001, 'SearchPlay', { NAVID = 'n1', SEQ = '16', ROOMID = '12', ARGS = '<params><param name="id">2002|2</param></params>' })
eq(respondTo('/launch/', 200, '').url, 'http://192.168.1.60:8060/launch/291097?contentId=081d1bd1-8a3c-4e0d-9b5f-1c2d3e4f5a6b&mediaType=series', 'Disney+ deep link')

------------------------------------------------------------------ channel not installed: offer to add it
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'n1', SEQ = '17', ROOMID = '12', ARGS = '<params><param name="id">2003</param></params>' })
eq(lastReply().DATA, '<NextScreen>WhereToWatchScreen</NextScreen>', 'uninstalled-only title opens the chooser')
ReceivedFromProxy(5001, 'GetWhereToWatch', { NAVID = 'n1', SEQ = '18', ARGS = '<params><param name="id">2003</param></params>' })
find(lastReply().DATA, '<id>2003|i1</id><title>Add Apple TV to the Roku</title>', 'install option offered')
ReceivedFromProxy(5001, 'SearchPlay', { NAVID = 'n1', SEQ = '19', ROOMID = '12', ARGS = '<params><param name="id">2003|i1</param></params>' })
local ins = respondTo('/install/', 200, '')
check(ins and ins.method == 'POST' and ins.url == 'http://192.168.1.60:8060/install/551012', 'opens the Apple TV install page on the Roku')
eq(pending('/launch/'), 0, 'install does not launch')
eq(lastReply().DATA, '', 'stays on the chooser after install')
eq(Roku.appsAt, 0, 'channel list marked stale after an install')
-- unknown service and other-country titles are not tappable
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'n1', SEQ = '20', ROOMID = '12', ARGS = '<params><param name="id">2006</param></params>' })
eq(lastReply().DATA, '', 'title with no usable channel does nothing')

------------------------------------------------------------------ recent list
ReceivedFromProxy(5001, 'GetRecent', { NAVID = 'n1', SEQ = '21' })
data = lastReply().DATA
check(data:find('The Bear', 1, true) < data:find('Dune', 1, true) and data:find('Dune', 1, true) < data:find('Wednesday', 1, true), 'recent list is newest first')
find(data, '<id>291097|081d1bd1-8a3c-4e0d-9b5f-1c2d3e4f5a6b</id>', 'recent entry keyed by channel and content')
find(data, '<subtitle>Disney Plus</subtitle>', 'recent entry names the channel')
-- relaunch moves it to the top and sends the same deep link
ReceivedFromProxy(5001, 'LaunchRecent', { NAVID = 'n1', SEQ = '22', ROOMID = '12', ARGS = '<params><param name="id">12|81231974</param></params>' })
eq(respondTo('/launch/', 200, '').url, 'http://192.168.1.60:8060/launch/12?contentId=81231974&mediaType=series', 'recent relaunches the same deep link')
eq(RecentList()[1].title, 'Wednesday', 'relaunched entry moves to the top')
eq(#RecentList(), 3, 'no duplicate entry')
-- size limit (3 in this test)
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'n1', SEQ = '23', ROOMID = '12', ARGS = '<params><param name="id">2005</param></params>' })
eq(respondTo('/launch/', 200, '').url, 'http://192.168.1.60:8060/launch/2595?contentId=GG5H5XQX4&mediaType=series', 'Crunchyroll deep link')
eq(#RecentList(), 3, 'recent list capped at its size')
eq(RecentList()[1].title, 'Frieren', 'newest on top')
ReceivedFromProxy(5001, 'RemoveRecent', { NAVID = 'n1', SEQ = '24', ARGS = '<params><param name="id">2595|GG5H5XQX4</param></params>' })
eq(#RecentList(), 2, 'entry removed')
eq(lastReply().DATA, '<NextScreen>RecentScreen</NextScreen>', 'list refreshed after removal')
ExecuteCommand('Resume Latest', { Room = '12' })
find(respondTo('/launch/', 200, '').url, '/launch/12?contentId=81231974', 'Resume Latest relaunches the top entry')
ReceivedFromProxy(5001, 'LaunchRecent', { NAVID = 'n1', SEQ = '25', ARGS = '<params><param name="id">nope</param></params>' })
eq(lastReply().ERROR, 'That entry is no longer in the list', 'stale recent id handled')

------------------------------------------------------------------ Limited mode
clear()
ReceivedFromProxy(5001, 'UP', {})
respondTo('/keypress/', 403, 'ECP command not allowed in Limited mode.')
find(Properties['Roku Status'], 'Control by mobile apps', 'Limited mode explained in the status')
Roku.apps, Roku.appsById = {}, {}
ReceivedFromProxy(5001, 'GetChannels', { NAVID = 'n2', SEQ = '30' })
respondTo('/query/apps', 403, 'ECP command not allowed in Limited mode.')
find(lastReply().ERROR or '', 'Network access, set to Enabled', 'Limited mode explained on screen')
ReceivedFromProxy(5001, 'GetChannels', { NAVID = 'n2', SEQ = '31' })
respondTo('/query/apps', 0, '', 'No route to host')
find(lastReply().ERROR or '', 'Roku unreachable: No route to host', 'offline explained on screen')
eq(Roku.online, false, 'marked offline')
check(stub.events[#stub.events] == 'Roku Offline', 'offline event fired')
ReceivedFromProxy(5001, 'GetChannels', { NAVID = 'n2', SEQ = '32' })
respondTo('/query/apps', 200, APPS_XML)
check(stub.events[#stub.events] == 'Roku Online', 'online event fired on recovery')

------------------------------------------------------------------ now playing + power
clear()
ReceivedFromProxy(5001, 'DEVICE_SELECTED', {})
eq(pending('/keypress/Power'), 0, 'no power command by default')
check(Timer.np ~= nil, 'now playing refresh timer started')
respondTo('/query/active-app', 200, '<active-app><app id="12" type="appl" version="5.1">Netflix</app></active-app>')
respondTo('/query/media-player', 200, player('play'))
eq(stub.variables['ACTIVE_APP'], 'Netflix', 'active app variable')
local progress
for _, m in ipairs(stub.proxyMessages) do if (m.command == 'SEND_EVENT' and m.params.NAME == 'ProgressChanged') then progress = m.params.EVTARGS end end
eq(progress, '<length>3600</length><offset>60</offset><label>1:00 / 1:00:00</label>', 'progress sent to the Now Playing bar')
ReceivedFromProxy(5001, 'DEVICE_DESELECTED', {})
check(Timer.np == nil, 'refresh timer stopped when deselected')
eq(#take('/keypress/'), 0, 'no key sent on room off by default')
Properties['Power Commands'] = 'Go Home when room turns off'
ReceivedFromProxy(5001, 'OFF', {})
find(take('/keypress/')[1].url, '/keypress/Home', 'Go Home option sends Home on room off')
Properties['Power Commands'] = 'Roku TV: power on and off'
ReceivedFromProxy(5001, 'ON', {})
check(#take('/keypress/PowerOn') == 1, 'Roku TV option powers on')
ReceivedFromProxy(5001, 'OFF', {})
check(#take('/keypress/PowerOff') == 1, 'Roku TV option powers off')
Properties['Power Commands'] = 'Off'
KillAllTimers()

------------------------------------------------------------------ programming
clear()
Properties['Select Room Source'] = 'Select Roku Bridge'
stub.roomDevice[12] = 555
ExecuteCommand('Launch Channel', { Channel = '12', Room = '12' })
local sel = stub.deviceMessages[#stub.deviceMessages]
check(sel and sel.command == 'SELECT_VIDEO_DEVICE' and sel.params.deviceid == stub.proxyDeviceId, 'optional room select targets this driver')
find(respondTo('/launch/', 200, '').url, '/launch/12', 'programmed channel launch')
stub.roomDevice[12] = stub.proxyDeviceId
local nSel = #stub.deviceMessages
ExecuteCommand('Launch Channel', { Channel = '12', Room = '12' })
eq(#stub.deviceMessages, nSel, 'no re-select when the room is already on Roku Bridge')
Properties['Select Room Source'] = 'Never'
clear()
ExecuteCommand('Launch Deep Link', { ['Channel ID'] = '2285', ['Content ID'] = 'a b/c', ['Media Type'] = 'episode' })
eq(respondTo('/launch/', 200, '').url, 'http://192.168.1.60:8060/launch/2285?contentId=a%20b%2Fc&mediaType=episode', 'deep link command URL-encodes the content id')
ExecuteCommand('Send Key', { Key = 'InstantReplay' })
find(take('/keypress/')[1].url, '/keypress/InstantReplay', 'Send Key command')
local cs = ChannelSelect()
check(#cs == 8 and cs[1].text == 'Crunchyroll' and cs[1].value == '2595', 'channel picker for programming')

-- Test Connection reads device info, then proves control works
ExecuteCommand('LUA_ACTION', { ACTION = 'Test Connection' })
respondTo('/query/device-info', 200, '<device-info><model-name>Roku Ultra</model-name><friendly-device-name>Theater Roku</friendly-device-name><software-version>14.6.0</software-version><ecp-setting-mode>enabled</ecp-setting-mode></device-info>')
check(respondTo('/query/apps', 200, APPS_XML) ~= nil, 'Test Connection verifies a real command')

print(string.format('%d passed, %d failed', passed, failed))
if (failed > 0) then os.exit(1) end
