-- Run from the repository root:  lua5.1 control4/test/test_search.lua
-- Exercises the in-Control4 search (Streaming Availability API) against a
-- fake C4 runtime. Fixtures follow the API's OpenAPI v4 field names.

package.path = 'control4/test/?.lua;' .. package.path
local stub = require('c4stub')

Properties = {
	['Bridge Address'] = '192.168.1.50',
	['API Key'] = '',
	['Wake on Select'] = 'Off',
	['Select Room Source'] = 'Never',
	['Launch Delay (ms)'] = '0',
	['After Launch'] = 'Go to Now Playing',
	['Rows'] = 'Continue + Up Next + New',
	['Max Items'] = '40',
	['Refresh Interval (s)'] = '0',
	['Debug Mode'] = 'Off',
	['Search API Key'] = '',
	['Search API Service'] = 'Movie of the Night',
	['Search Country'] = 'us',
	['Search Includes'] = 'Subscription and free',
	['Show Titles Not On Shield'] = 'Yes',
	['Search Status'] = '',
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
	check(type(s) == 'string' and s:find(pat, 1, true) ~= nil, msg .. ' (missing "' .. pat .. '" in ' .. tostring(s):sub(1, 300) .. ')')
end
local function lacks(s, pat, msg)
	check(type(s) == 'string' and s:find(pat, 1, true) == nil, msg .. ' (unexpected "' .. pat .. '")')
end
local DOT = ' \194\183 '

-- complete the first outstanding request whose URL contains `pat`
local function respondTo(pat, code, body, err)
	for i, r in ipairs(stub.urlRequests) do
		if (r.url:find(pat, 1, true)) then
			table.remove(stub.urlRequests, i)
			r.callback(1, body, code, { ['Content-Type'] = 'application/json' }, err)
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
local function drainLaunches(code, body)
	local seen = {}
	while (pending('/api/launch') > 0) do
		table.insert(seen, respondTo('/api/launch', code or 200, body or '{"ok":true,"message":"launched"}'))
	end
	return seen
end

local APPS = '{"ok":true,"apps":[' ..
	'{"package":"com.netflix.ninja","label":"Netflix","icon":""},' ..
	'{"package":"com.wbd.stream","label":"HBO Max","icon":""},' ..
	'{"package":"com.hulu.livingroomplus","label":"Hulu","icon":""},' ..
	'{"package":"com.disney.disneyplus","label":"Disney+","icon":""}]}'

local function svc(id, name)
	return '{"id":"' .. id .. '","name":"' .. name .. '","homePage":"https://example.com/","themeColorCode":"#000000",' ..
		'"imageSet":{"lightThemeImage":"x","darkThemeImage":"x","whiteImage":"x"}}'
end
local function poster(id)
	local b = 'https://cdn.movieofthenight.com/show/' .. id .. '/poster/vertical/en/'
	return '{"verticalPoster":{"w240":"' .. b .. '240.jpg","w360":"' .. b .. '360.jpg","w480":"' .. b .. '480.jpg","w600":"' .. b .. '600.jpg","w720":"' .. b .. '720.jpg"},' ..
		'"horizontalPoster":{"w360":"h","w480":"h","w720":"h","w1080":"h","w1440":"h"}}'
end
local function opt(service, otype, link, extra)
	return '{"service":' .. service .. ',"type":"' .. otype .. '","link":"' .. link .. '","audios":[],"subtitles":[],' ..
		'"expiresSoon":false,"availableSince":1700000000' .. (extra or '') .. '}'
end
local function show(id, stype, title, yearField, options)
	return '{"itemType":"show","showType":"' .. stype .. '","id":"' .. id .. '","imdbId":"tt' .. id .. '","tmdbId":"' .. stype .. '/' .. id .. '",' ..
		'"title":"' .. title .. '","overview":"o","' .. yearField .. ':2024,"originalTitle":"' .. title .. '","genres":[],"cast":[],"rating":80,' ..
		'"imageSet":' .. poster(id) .. ',"streamingOptions":' .. options .. '}'
end

local SEARCH_JSON = '[' ..
	-- movie: Max subscription (with a direct video link) + a 4K rental on Prime
	show('1001', 'movie', 'Dune: Part Two', 'releaseYear"', '{"us":[' ..
		opt(svc('hbo', 'Max'), 'subscription', 'https://play.max.com/movie/abc', ',"videoLink":"https://play.max.com/video/watch/abc/def","quality":"uhd"') .. ',' ..
		opt(svc('prime', 'Prime Video'), 'rent', 'https://www.amazon.com/gp/video/detail/B0X', ',"quality":"uhd","price":{"amount":"5.99","currency":"USD","formatted":"5.99 USD"}') ..
		']}') .. ',' ..
	-- series on two installed apps; Hulu listed twice (HD and 4K)
	show('1002', 'series', 'The Bear', 'firstAirYear"', '{"us":[' ..
		opt(svc('hulu', 'Hulu'), 'subscription', 'https://www.hulu.com/series/the-bear-05eb6a8e', ',"quality":"hd"') .. ',' ..
		opt(svc('disney', 'Disney+'), 'subscription', 'https://www.disneyplus.com/series/the-bear/1Gnd', ',"quality":"uhd","expiresSoon":true') .. ',' ..
		opt(svc('hulu', 'Hulu'), 'subscription', 'https://www.hulu.com/series/the-bear-05eb6a8e', ',"quality":"uhd"') ..
		']}') .. ',' ..
	-- only on a service whose app is not installed
	show('1003', 'series', 'Severance', 'firstAirYear"', '{"us":[' ..
		opt(svc('apple', 'Apple TV'), 'subscription', 'https://tv.apple.com/us/show/severance/umc.cmc.1srk', ',"quality":"uhd"') ..
		']}') .. ',' ..
	-- Netflix series offered in HD and 4K
	show('1004', 'series', 'Wednesday', 'firstAirYear"', '{"us":[' ..
		opt(svc('netflix', 'Netflix'), 'subscription', 'https://www.netflix.com/title/81231974/', ',"quality":"hd"') .. ',' ..
		opt(svc('netflix', 'Netflix'), 'subscription', 'https://www.netflix.com/title/81231974/', ',"quality":"uhd"') ..
		']}') .. ',' ..
	-- streams only in another country
	show('1005', 'series', 'Andor', 'firstAirYear"', '{"gb":[' ..
		opt(svc('disney', 'Disney+'), 'subscription', 'https://www.disneyplus.com/series/andor/x', ',"quality":"uhd"') ..
		']}') ..
	']'

local function search(navId, seq, query, filter)
	local argsXml = '<params><param name="search">' .. (query or '') .. '</param>' ..
		(filter and ('<param name="search_filter">' .. filter .. '</param>') or '') .. '</params>'
	ReceivedFromProxy(5001, 'SearchResults', { NAVID = navId, SEQ = seq, ROOMID = '12', ARGS = argsXml })
end

------------------------------------------------------------------ fixture sanity
local decoded = JSON.decode(SEARCH_JSON)
check(type(decoded) == 'table' and #decoded == 5, 'fixture decodes to five shows')

------------------------------------------------------------------ name matching
eq(NormName('Disney+'), 'disney', 'Disney+ normalises')
eq(NormName('Disney Plus'), 'disney', 'Disney Plus normalises')
eq(NormName('Paramount+'), 'paramount', 'Paramount+ normalises')
eq(NormName('HBO Max'), 'hbomax', 'HBO Max normalises')

------------------------------------------------------------------ no key: explain, offer TV search, call nothing
search('nav1', '1', 'the bear')
respondTo('/api/apps', 200, APPS)
eq(pending('movieofthenight'), 0, 'no API call without a key')
local data = lastReply().DATA
find(data, 'Add a Search API Key in Composer', 'no-key notice shown')
find(data, '<default_action>SearchOnTv</default_action>', 'TV search fallback offered')
eq(Properties['Search Status'], 'Add a Search API Key in Composer to see results here', 'status explains missing key')

------------------------------------------------------------------ search with a key
Properties['Search API Key'] = 'k-123'
OnPropertyChanged('Search API Key')
Bridge.apps, Bridge.appsByPackage = {}, {}
search('nav1', '2', 'the bear')
-- installed apps are fetched first when unknown
check(respondTo('/api/apps', 200, APPS) ~= nil, 'installed apps fetched before searching')
local apiReq = stub.urlRequests[#stub.urlRequests]
eq(apiReq.url, 'https://api.movieofthenight.com/v4/shows/search/title?title=the%20bear&country=us&series_granularity=show&output_language=en', 'search URL, scoped to the country')
eq(apiReq.headers['X-API-Key'], 'k-123', 'API key header')
respondTo('movieofthenight', 200, SEARCH_JSON)
data = lastReply().DATA
eq(lastReply().NAVID, 'nav1', 'reply routed to the asking navigator')
find(data, '<title>Dune: Part Two</title>', 'movie listed')
find(data, '<image_list width="240" height="360">https://cdn.movieofthenight.com/show/1001/poster/vertical/en/240.jpg</image_list>', 'poster attached')
find(data, '<subtitle>2024' .. DOT .. 'Movie' .. DOT .. 'HBO Max</subtitle>', 'movie subtitle names the installed app, rental hidden')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'Hulu, Disney+</subtitle>', 'series on two apps, Hulu deduplicated')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'Netflix</subtitle>', 'Netflix HD/4K offers collapse to one')
find(data, "<title>Not on your Shield&apos;s apps</title><isHeader>true</isHeader>", 'unavailable titles under their own heading')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'On Apple TV (app not on Shield)</subtitle>', 'explains which service carries it')
find(data, '<subtitle>2024' .. DOT .. 'Series' .. DOT .. 'Not streaming in US</subtitle>', 'other-country-only title marked')
local pBear, pSev = data:find('The Bear', 1, true), data:find('Severance', 1, true)
check(pBear < pSev, 'playable results listed before unavailable ones')
find(data, '<title>Search &quot;the bear&quot; on the TV</title>', 'TV search fallback at the bottom')
find(data, '<id>1002</id><title>The Bear</title>', 'show id carried for drill-down')
find(Properties['Search Status'], 'OK: 5 results for "the bear" in US', 'status reports the result count')

-- Navigator re-requests the list when returning to it: served from cache
search('nav1', '3', 'the bear')
eq(pending('movieofthenight'), 0, 'repeat search served from cache')
find(lastReply().DATA, '<title>Dune: Part Two</title>', 'cached results returned')

------------------------------------------------------------------ history
eq(PersistData.searchHistory[1], 'the bear', 'query saved to history')
ReceivedFromProxy(5001, 'GetSearchHistory', { NAVID = 'nav1', SEQ = '4' })
eq(lastReply().DATA, '<List><item><name>the bear</name></item></List>', 'history served to the search box')

------------------------------------------------------------------ one app: tap plays immediately
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'nav1', SEQ = '5', ROOMID = '12', ARGS = '<params><param name="id">1001</param></params>' })
eq(lastReply().DATA, '<NextScreen>#nowplaying</NextScreen>', 'single-app title plays without another screen')
local launches = drainLaunches()
eq(#launches, 1, 'one launch for a single-app title')
eq(launches[1].data, '{"intentUri":"intent://play.max.com/video/watch/abc/def#Intent;scheme=https;package=com.wbd.stream;action=android.intent.action.VIEW;end"}',
	'movie uses its direct video link, pinned to the Max app')
eq(stub.variables['LAST_LAUNCHED_TITLE'], 'Dune: Part Two', 'now playing title set')

------------------------------------------------------------------ Netflix title link gets source=30
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'nav1', SEQ = '6', ROOMID = '12', ARGS = '<params><param name="id">1004</param></params>' })
launches = drainLaunches()
eq(launches[1].data, '{"intentUri":"intent://www.netflix.com/title/81231974/?source=30#Intent;scheme=https;package=com.netflix.ninja;action=android.intent.action.VIEW;end"}',
	'Netflix title link gains source=30 and is pinned to the Netflix app')

------------------------------------------------------------------ already in Continue Watching: resume instead
Bridge.items = { { id = 900, package = 'com.netflix.ninja', app = 'Netflix', title = 'Wednesday', season = '2', episode = '3',
	watchNextType = 'CONTINUE', progress = 40, positionMs = 1000, durationMs = 3000 } }
Bridge.itemsById = { ['900'] = Bridge.items[1] }
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'nav1', SEQ = '7', ROOMID = '12', ARGS = '<params><param name="id">1004</param></params>' })
launches = drainLaunches()
eq(launches[1].data, '{"id":900}', 'in-progress title resumes from its Continue Watching row')

-- where-to-watch lists a Resume row first when one exists
ReceivedFromProxy(5001, 'GetWhereToWatch', { NAVID = 'nav1', SEQ = '8', ARGS = '<params><param name="id">1004</param></params>' })
data = lastReply().DATA
find(data, '<id>1004|r1</id><title>Resume in Netflix</title>', 'resume row offered')
find(data, 'S2 E3', 'resume row shows the episode')
find(data, '<id>1004|1</id><title>Netflix</title><subtitle>Included with subscription' .. DOT .. '4K</subtitle>', 'best quality kept for the plain option')
ReceivedFromProxy(5001, 'SearchPlay', { NAVID = 'nav1', SEQ = '9', ROOMID = '12', ARGS = '<params><param name="id">1004|1</param></params>' })
launches = drainLaunches()
find(launches[1].data, 'netflix.com/title/81231974', 'choosing the plain option opens the title, not the resume row')
Bridge.items, Bridge.itemsById = {}, {}

------------------------------------------------------------------ several apps: where-to-watch screen
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'nav1', SEQ = '10', ROOMID = '12', ARGS = '<params><param name="id">1002</param></params>' })
eq(lastReply().DATA, '<NextScreen>WhereToWatchScreen</NextScreen>', 'multi-app title opens the where-to-watch list')
eq(pending('/api/launch'), 0, 'nothing launched until a service is chosen')
-- Navigator may omit the id on the next screen: the driver remembers the pick
ReceivedFromProxy(5001, 'GetWhereToWatch', { NAVID = 'nav1', SEQ = '11', ARGS = '' })
data = lastReply().DATA
find(data, '<title>The Bear</title><isHeader>true</isHeader>', 'show title as header')
find(data, '<id>1002|1</id><title>Hulu</title><subtitle>Included with subscription' .. DOT .. '4K</subtitle>', 'Hulu option, best quality')
find(data, '<id>1002|2</id><title>Disney+</title><subtitle>Included with subscription' .. DOT .. '4K' .. DOT .. 'Leaving soon</subtitle>', 'Disney+ option flags expiry')

-- a refused deep link falls back to opening the app
ReceivedFromProxy(5001, 'SearchPlay', { NAVID = 'nav1', SEQ = '12', ROOMID = '12', ARGS = '<params><param name="id">1002|2</param></params>' })
eq(lastReply().DATA, '<NextScreen>#nowplaying</NextScreen>', 'choice plays and moves to Now Playing')
local first = respondTo('/api/launch', 400, '{"ok":false,"message":"no app can handle: https://www.disneyplus.com/series/the-bear/1Gnd"}')
find(first.data, 'package=com.disney.disneyplus', 'Disney+ link pinned to the Disney+ app')
local fallback = drainLaunches()
eq(#fallback, 1, 'one fallback launch')
eq(fallback[1] and fallback[1].data, '{"package":"com.disney.disneyplus"}', 'falls back to opening Disney+')

------------------------------------------------------------------ includes property
Properties['Search Includes'] = 'Everything (incl. rent/buy)'
local playable, missing = ShowOptions(Finder.shows['1001'])
eq(#playable, 1, 'rental on a non-installed app is not playable')
eq(#missing, 1, 'but is listed when rent/buy is included')
eq(OptionDescription(missing[1].opt), 'Rent 5.99 USD' .. DOT .. '4K', 'rental described with its price')
Properties['Search Includes'] = 'Subscription and free'
playable, missing = ShowOptions(Finder.shows['1001'])
eq(#missing, 0, 'rentals hidden by default')

------------------------------------------------------------------ TV search fallback uses the navigator's last query
ReceivedFromProxy(5001, 'SearchOnTv', { NAVID = 'nav1', SEQ = '13', ROOMID = '12' })
local tv = drainLaunches()
find(tv[1] and tv[1].data or '', 'GLOBAL_SEARCH', 'TV search fired')
find(tv[1] and tv[1].data or '', 'S.query=the%20bear', 'with the last query')

------------------------------------------------------------------ filters, country, RapidAPI
search('nav2', '20', 'dune', 'movie')
find(stub.urlRequests[#stub.urlRequests].url, '&show_type=movie', 'Movies filter narrows to movies')
respondTo('movieofthenight', 200, '[]')
find(lastReply().DATA, 'No matches for &quot;dune&quot;', 'empty result explained')

Properties['Search Country'] = 'CA'
OnPropertyChanged('Search Country')
eq(SearchCountry(), 'ca', 'country lower-cased')
Properties['Search Country'] = 'usa'
eq(SearchCountry(), 'us', 'invalid country falls back to us')
Properties['Search Country'] = 'us'

Properties['Search API Service'] = 'RapidAPI'
OnPropertyChanged('Search API Service')
search('nav2', '21', 'andor')
local rq = stub.urlRequests[#stub.urlRequests]
eq(rq.url, 'https://streaming-availability.p.rapidapi.com/shows/search/title?title=andor&country=us&series_granularity=show&output_language=en', 'RapidAPI host, no /v4')
eq(rq.headers['X-RapidAPI-Key'], 'k-123', 'RapidAPI key header')
eq(rq.headers['X-RapidAPI-Host'], 'streaming-availability.p.rapidapi.com', 'RapidAPI host header')
respondTo('rapidapi', 200, '[]')
Properties['Search API Service'] = 'Movie of the Night'
OnPropertyChanged('Search API Service')

------------------------------------------------------------------ errors
search('nav3', '30', 'severance')
respondTo('movieofthenight', 401, '{"message":"Invalid API key"}')
find(lastReply().DATA, 'rejected the API key', 'bad key explained in the list')
find(lastReply().DATA, 'SearchOnTv', 'TV search still offered on error')
eq(Properties['Search Status'], 'The search service rejected the API key; check it in Composer', 'status shows the key problem')
search('nav3', '31', 'severance')
respondTo('movieofthenight', 429, '{"message":"Too many requests"}')
find(lastReply().DATA, 'Search limit reached', 'quota explained')
search('nav3', '32', 'severance')
respondTo('movieofthenight', 0, '', 'Could not resolve host')
find(lastReply().DATA, 'search service unreachable', 'network failure explained')

------------------------------------------------------------------ expired pick
ReceivedFromProxy(5001, 'SearchPick', { NAVID = 'nav3', SEQ = '33', ROOMID = '12', ARGS = '<params><param name="id">nope</param></params>' })
eq(lastReply().ERROR, 'That result has expired; search again', 'unknown result id handled')

------------------------------------------------------------------ Search tab "Show results here"
PersistData.searchQuery = 'wednesday'
ReceivedFromProxy(5001, 'SearchHere', { NAVID = 'nav4', SEQ = '40' })
eq(lastReply().DATA, '<NextScreen>SearchResultsScreen</NextScreen>', 'button opens the results screen')
search('nav4', '41', '')
find(stub.urlRequests[#stub.urlRequests].url, 'title=wednesday', 'results screen uses the typed query')
respondTo('movieofthenight', 200, SEARCH_JSON)
find(lastReply().DATA, '<title>Wednesday</title>', 'typed-query results shown')

------------------------------------------------------------------ Composer Test Search action
ExecuteCommand('LUA_ACTION', { ACTION = 'Test Search' })
respondTo('/api/apps', 200, APPS)
-- "Severance" is not cached yet for this country/filter
respondTo('movieofthenight', 200, SEARCH_JSON)
find(Properties['Search Status'], 'OK: 5 results for "Severance" in US', 'Test Search reports into the status property')

print(string.format('%d passed, %d failed', passed, failed))
if (failed > 0) then os.exit(1) end
