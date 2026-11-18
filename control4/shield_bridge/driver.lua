--[[
Shield Bridge for Control4 - Media Service Proxy driver

Presents the NVIDIA Shield's system-wide "Continue Watching" (Android TV
Watch Next) list inside Navigator and launches the selected show straight
into playback through the Shield Bridge app running on the Shield.

The driver talks HTTP to the bridge app (see docs/API.md). It sits in the
room's video path between the Shield's own control driver and the display,
so selecting it in Watch powers the path up, and remote/transport commands
are forwarded to whatever driver is bound to its Video In connection.

Lua 5.1 (Control4 DriverWorks).
--]]

DRIVER_VERSION = "0.1.1"

MSP_PROXY = 5001          -- media_service proxy binding
VIDEO_IN_BINDING = 1001   -- the Shield's HDMI output is bound here
AUDIO_IN_BINDING = 3001

DEFAULT_BRIDGE_PORT = 8765

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

Bridge = Bridge or {
	online = nil,          -- nil = unknown, true/false after first contact
	items = {},            -- last /api/continue result (array of tables)
	itemsById = {},
	apps = {},             -- last /api/apps result
	appsByPackage = {},
	lastItemsAt = 0,
	lastLaunched = nil,    -- table describing the last launched item
}

Timer = Timer or {}
Navigators = Navigators or {}
DEBUGPRINT = false
ShieldDeviceId = nil      -- device bound to VIDEO_IN_BINDING, resolved lazily

PersistData = PersistData or {}

-------------------------------------------------------------------------------
-- Small utilities
-------------------------------------------------------------------------------

function dbg(s, ...)
	if (DEBUGPRINT) then
		print(os.date('%x %X : ') .. tostring(s or ''), ...)
	end
end

function trim(s)
	if (s == nil) then return '' end
	return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

function XMLEncode(s)
	if (s == nil) then return '' end
	s = tostring(s)
	s = s:gsub('&', '&amp;')
	s = s:gsub('"', '&quot;')
	s = s:gsub('<', '&lt;')
	s = s:gsub('>', '&gt;')
	s = s:gsub("'", '&apos;')
	return s
end

-- Builds "<name>value</name>" with the value XML-encoded.
function XMLTag(name, value)
	return '<' .. name .. '>' .. XMLEncode(value) .. '</' .. name .. '>'
end

function FormatSeconds(totalSeconds)
	totalSeconds = math.floor(tonumber(totalSeconds) or 0)
	if (totalSeconds < 0) then totalSeconds = 0 end
	local h = math.floor(totalSeconds / 3600)
	local m = math.floor((totalSeconds % 3600) / 60)
	if (h > 0) then
		return string.format('%dh %02dm', h, m)
	end
	return string.format('%dm', m)
end

function KillTimer(name)
	if (Timer[name]) then
		Timer[name]:Cancel()
		Timer[name] = nil
	end
end

function KillAllTimers()
	for name, _ in pairs(Timer) do KillTimer(name) end
end

-------------------------------------------------------------------------------
-- JSON (pure Lua, enough for the bridge's responses and small POST bodies)
-------------------------------------------------------------------------------

JSON = {}

do
	local function utf8char(cp)
		if (cp < 0x80) then
			return string.char(cp)
		elseif (cp < 0x800) then
			return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
		elseif (cp < 0x10000) then
			return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
		else
			return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + (math.floor(cp / 0x1000) % 0x40),
				0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
		end
	end

	local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

	local decodeValue

	local function skipWs(s, i)
		local _, e = s:find('^[ \t\r\n]*', i)
		return e + 1
	end

	local function decodeString(s, i)
		-- s:sub(i, i) == '"'
		local out = {}
		i = i + 1
		while true do
			local c = s:sub(i, i)
			if (c == '') then error('unterminated string') end
			if (c == '"') then
				return table.concat(out), i + 1
			elseif (c == '\\') then
				local e = s:sub(i + 1, i + 1)
				if (e == 'u') then
					local hex = s:sub(i + 2, i + 5)
					local cp = tonumber(hex, 16)
					if (not cp) then error('bad unicode escape') end
					i = i + 6
					if (cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == '\\u') then
						local lo = tonumber(s:sub(i + 2, i + 5), 16)
						if (lo and lo >= 0xDC00 and lo <= 0xDFFF) then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
							i = i + 6
						end
					end
					table.insert(out, utf8char(cp))
				else
					local r = escapes[e]
					if (not r) then error('bad escape \\' .. e) end
					table.insert(out, r)
					i = i + 2
				end
			else
				-- copy a run of plain characters at once
				local j = s:find('["\\]', i)
				if (not j) then error('unterminated string') end
				table.insert(out, s:sub(i, j - 1))
				i = j
			end
		end
	end

	local function decodeNumber(s, i)
		local numStr = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
		if (not numStr or numStr == '') then error('bad number at ' .. i) end
		local n = tonumber(numStr)
		if (n == nil) then error('bad number ' .. numStr) end
		return n, i + #numStr
	end

	local function decodeArray(s, i)
		local arr = {}
		i = skipWs(s, i + 1)
		if (s:sub(i, i) == ']') then return arr, i + 1 end
		while true do
			local v
			v, i = decodeValue(s, i)
			table.insert(arr, v)
			i = skipWs(s, i)
			local c = s:sub(i, i)
			if (c == ',') then
				i = skipWs(s, i + 1)
			elseif (c == ']') then
				return arr, i + 1
			else
				error('expected , or ] at ' .. i)
			end
		end
	end

	local function decodeObject(s, i)
		local obj = {}
		i = skipWs(s, i + 1)
		if (s:sub(i, i) == '}') then return obj, i + 1 end
		while true do
			if (s:sub(i, i) ~= '"') then error('expected string key at ' .. i) end
			local k
			k, i = decodeString(s, i)
			i = skipWs(s, i)
			if (s:sub(i, i) ~= ':') then error('expected : at ' .. i) end
			i = skipWs(s, i + 1)
			local v
			v, i = decodeValue(s, i)
			if (v ~= nil) then obj[k] = v end
			i = skipWs(s, i)
			local c = s:sub(i, i)
			if (c == ',') then
				i = skipWs(s, i + 1)
			elseif (c == '}') then
				return obj, i + 1
			else
				error('expected , or } at ' .. i)
			end
		end
	end

	decodeValue = function(s, i)
		i = skipWs(s, i)
		local c = s:sub(i, i)
		if (c == '{') then return decodeObject(s, i)
		elseif (c == '[') then return decodeArray(s, i)
		elseif (c == '"') then return decodeString(s, i)
		elseif (c == '-' or c:match('%d')) then return decodeNumber(s, i)
		elseif (s:sub(i, i + 3) == 'true') then return true, i + 4
		elseif (s:sub(i, i + 4) == 'false') then return false, i + 5
		elseif (s:sub(i, i + 3) == 'null') then return nil, i + 4
		end
		error('unexpected character "' .. c .. '" at ' .. i)
	end

	-- Returns the decoded value, or nil plus an error message.
	function JSON.decode(s)
		if (type(s) ~= 'string') then return nil, 'not a string' end
		local ok, v, i = pcall(decodeValue, s, 1)
		if (not ok) then return nil, v end
		return v
	end

	local function encodeString(s)
		s = tostring(s)
		s = s:gsub('[%c"\\]', function(c)
			if (c == '"') then return '\\"' end
			if (c == '\\') then return '\\\\' end
			if (c == '\n') then return '\\n' end
			if (c == '\r') then return '\\r' end
			if (c == '\t') then return '\\t' end
			return string.format('\\u%04x', c:byte())
		end)
		return '"' .. s .. '"'
	end

	-- Encodes flat or nested tables. Tables with only 1..n integer keys become
	-- arrays; everything else becomes an object with sorted keys.
	function JSON.encode(v)
		local t = type(v)
		if (v == nil) then return 'null' end
		if (t == 'boolean') then return v and 'true' or 'false' end
		if (t == 'number') then
			if (v ~= v or v == math.huge or v == -math.huge) then return 'null' end
			if (math.floor(v) == v) then return string.format('%d', v) end
			return tostring(v)
		end
		if (t == 'string') then return encodeString(v) end
		if (t == 'table') then
			local n = #v
			local isArray = (n > 0)
			if (isArray) then
				for k, _ in pairs(v) do
					if (type(k) ~= 'number' or k < 1 or k > n or math.floor(k) ~= k) then isArray = false break end
				end
			end
			local parts = {}
			if (isArray) then
				for i = 1, n do table.insert(parts, JSON.encode(v[i])) end
				return '[' .. table.concat(parts, ',') .. ']'
			end
			local keys = {}
			for k, _ in pairs(v) do table.insert(keys, tostring(k)) end
			table.sort(keys)
			for _, k in ipairs(keys) do
				local val = v[k]
				if (val == nil) then val = v[tonumber(k)] end
				table.insert(parts, encodeString(k) .. ':' .. JSON.encode(val))
			end
			return '{' .. table.concat(parts, ',') .. '}'
		end
		return 'null'
	end
end

-------------------------------------------------------------------------------
-- Bridge HTTP client
-------------------------------------------------------------------------------

function BridgeBaseUrl()
	local addr = trim(Properties['Bridge Address'])
	if (addr == '') then return nil end
	addr = addr:gsub('^https?://', ''):gsub('/+$', '')
	if (not addr:find(':')) then
		addr = addr .. ':' .. DEFAULT_BRIDGE_PORT
	end
	return 'http://' .. addr
end

function BridgeHeaders(extra)
	local h = extra or {}
	local key = trim(Properties['API Key'])
	if (key ~= '') then h['X-Api-Key'] = key end
	return h
end

-- Fires an HTTP request at the bridge. callback(err, data, code) receives the
-- decoded JSON body (or raw string when not JSON). Never throws.
function BridgeRequest(method, path, body, callback)
	local base = BridgeBaseUrl()
	if (not base) then
		if (callback) then callback('Bridge Address property is empty') end
		return
	end
	local url = base .. path
	dbg('HTTP ' .. method .. ' ' .. url)

	local function handle(ticketId, strData, responseCode, tHeaders, strError)
		strData = strData or ''
		responseCode = tonumber(responseCode) or 0
		if (strError and strError ~= '') then
			dbg('HTTP error: ' .. tostring(strError))
			SetBridgeOnline(false, tostring(strError))
			if (callback) then callback(tostring(strError), nil, responseCode) end
			return
		end
		local data = nil
		if (strData:match('^%s*[%[{]')) then
			local decoded, err = JSON.decode(strData)
			if (decoded == nil) then
				dbg('JSON decode failed: ' .. tostring(err))
				if (callback) then callback('bad JSON from bridge: ' .. tostring(err), nil, responseCode) end
				return
			end
			data = decoded
		else
			data = strData
		end
		if (responseCode < 200 or responseCode >= 300) then
			local msg = 'HTTP ' .. responseCode
			if (type(data) == 'table' and data.error) then msg = msg .. ': ' .. tostring(data.error) end
			if (responseCode == 0) then SetBridgeOnline(false, msg) end
			if (callback) then callback(msg, data, responseCode) end
			return
		end
		SetBridgeOnline(true)
		if (callback) then callback(nil, data, responseCode) end
	end

	local ok, err = pcall(function()
		if (method == 'POST') then
			local payload = JSON.encode(body or {})
			C4:urlPost(url, payload, BridgeHeaders({ ['Content-Type'] = 'application/json' }), false, handle)
		else
			C4:urlGet(url, BridgeHeaders(), false, handle)
		end
	end)
	if (not ok) then
		dbg('C4:url call failed: ' .. tostring(err))
		if (callback) then callback('request failed: ' .. tostring(err)) end
	end
end

function SetBridgeOnline(online, reason)
	local was = Bridge.online
	Bridge.online = online
	if (was ~= online) then
		local status = online and 'Online' or ('Offline' .. (reason and (' (' .. reason .. ')') or ''))
		C4:UpdateProperty('Bridge Status', status)
		C4:SetVariable('BRIDGE_ONLINE', online and 'true' or 'false')
		C4:FireEvent(online and 'Bridge Online' or 'Bridge Offline')
	end
end

-------------------------------------------------------------------------------
-- Data: Continue Watching and Apps
-------------------------------------------------------------------------------

function RowTypesParam()
	local mode = Properties['Rows'] or ''
	if (mode == 'Continue Watching only') then return 'CONTINUE' end
	if (mode == 'Everything') then return '' end
	return 'CONTINUE,NEXT,NEW'
end

function MaxItems()
	return tonumber(Properties['Max Items']) or 40
end

-- callback(err, items)
function FetchContinue(callback)
	local path = '/api/continue?limit=' .. MaxItems()
	local types = RowTypesParam()
	if (types ~= '') then path = path .. '&types=' .. types end
	BridgeRequest('GET', path, nil, function(err, data)
		if (err) then
			if (callback) then callback(err, Bridge.items) end
			return
		end
		local items = (type(data) == 'table') and data.items or nil
		if (type(items) ~= 'table') then
			if (callback) then callback('bridge reply had no items', Bridge.items) end
			return
		end
		Bridge.items = items
		Bridge.itemsById = {}
		for _, item in ipairs(items) do
			Bridge.itemsById[tostring(item.id)] = item
		end
		Bridge.lastItemsAt = os.time()
		if (callback) then callback(nil, items) end
	end)
end

function FetchApps(callback)
	BridgeRequest('GET', '/api/apps', nil, function(err, data)
		if (err) then
			if (callback) then callback(err, Bridge.apps) end
			return
		end
		local apps = (type(data) == 'table') and data.apps or nil
		if (type(apps) ~= 'table') then
			if (callback) then callback('bridge reply had no apps', Bridge.apps) end
			return
		end
		Bridge.apps = apps
		Bridge.appsByPackage = {}
		for _, app in ipairs(apps) do
			Bridge.appsByPackage[tostring(app.package)] = app
		end
		if (callback) then callback(nil, apps) end
	end)
end

-- One-line description under the title: "Netflix · S2 E4 · 36% watched · 22m left"
function ItemSubtitle(item)
	local parts = {}
	if (item.app and item.app ~= '') then table.insert(parts, item.app) end
	local se = ''
	if (item.season and item.season ~= '') then se = 'S' .. item.season end
	if (item.episode and item.episode ~= '') then se = se .. (se ~= '' and ' ' or '') .. 'E' .. item.episode end
	if (se ~= '') then table.insert(parts, se) end
	if (item.episodeTitle and item.episodeTitle ~= '' and item.episodeTitle ~= item.title) then
		table.insert(parts, item.episodeTitle)
	end
	local wt = item.watchNextType
	if (wt == 'CONTINUE') then
		local pct = tonumber(item.progress) or 0
		if (pct > 0) then table.insert(parts, pct .. '% watched') end
	elseif (wt == 'NEXT') then
		table.insert(parts, 'Next episode')
	elseif (wt == 'NEW') then
		table.insert(parts, 'New episode')
	elseif (wt == 'WATCHLIST') then
		table.insert(parts, 'Watchlist')
	end
	return table.concat(parts, ' \194\183 ')  -- middle dot
end

function ItemLength(item)
	local pos = tonumber(item.positionMs) or 0
	local dur = tonumber(item.durationMs) or 0
	if (dur > 0 and item.watchNextType == 'CONTINUE' and pos > 0) then
		return FormatSeconds((dur - pos) / 1000) .. ' left'
	elseif (dur > 0) then
		return FormatSeconds(dur / 1000)
	end
	return ''
end

function ItemXml(item)
	local x = { '<item>' }
	table.insert(x, XMLTag('id', item.id))
	table.insert(x, XMLTag('title', (item.title and item.title ~= '') and item.title or (item.app or 'Untitled')))
	table.insert(x, XMLTag('subtitle', ItemSubtitle(item)))
	local len = ItemLength(item)
	if (len ~= '') then table.insert(x, XMLTag('duration', len)) end
	if (item.art and item.art ~= '') then
		local w = tonumber(item.artWidth) or 300
		local h = tonumber(item.artHeight) or 169
		table.insert(x, '<image_list width="' .. w .. '" height="' .. h .. '">' .. XMLEncode(item.art) .. '</image_list>')
	end
	table.insert(x, '<default_action>LaunchItem</default_action>')
	table.insert(x, '<actions_list>LaunchItem FavoriteToRoom</actions_list>')
	table.insert(x, '</item>')
	return table.concat(x)
end

function HeaderXml(text)
	return '<item>' .. XMLTag('title', text) .. '<isHeader>true</isHeader></item>'
end

-- Groups rows by Watch Next type under headers, keeping bridge order within a group.
function BuildContinueList(items, notice)
	local groups = {
		{ key = 'CONTINUE', title = 'Continue Watching' },
		{ key = 'NEXT', title = 'Up Next' },
		{ key = 'NEW', title = 'New Episodes' },
		{ key = 'WATCHLIST', title = 'Watchlist' },
		{ key = 'OTHER', title = 'More' },
	}
	local byGroup = {}
	for _, item in ipairs(items or {}) do
		local k = item.watchNextType
		if (k ~= 'CONTINUE' and k ~= 'NEXT' and k ~= 'NEW' and k ~= 'WATCHLIST') then k = 'OTHER' end
		byGroup[k] = byGroup[k] or {}
		table.insert(byGroup[k], item)
	end
	local x = { '<List>' }
	if (notice) then
		table.insert(x, HeaderXml(notice))
	end
	local count = 0
	for _, g in ipairs(groups) do
		local list = byGroup[g.key]
		if (list and #list > 0) then
			table.insert(x, HeaderXml(g.title))
			for _, item in ipairs(list) do
				table.insert(x, ItemXml(item))
				count = count + 1
			end
		end
	end
	if (count == 0) then
		table.insert(x, '<item>' .. XMLTag('title', 'Nothing to continue yet') ..
			XMLTag('subtitle', 'Watch part of something on the Shield and it will appear here') .. '</item>')
	end
	table.insert(x, '</List>')
	return table.concat(x)
end

function BuildAppsList(apps)
	local x = { '<List>' }
	for _, app in ipairs(apps or {}) do
		table.insert(x, '<item>')
		table.insert(x, XMLTag('id', app.package))
		table.insert(x, XMLTag('title', app.label or app.package))
		if (app.icon and app.icon ~= '') then
			table.insert(x, '<image_list width="320" height="180">' .. XMLEncode(app.icon) .. '</image_list>')
		end
		table.insert(x, '<default_action>LaunchApp</default_action>')
		table.insert(x, '<actions_list>LaunchApp FavoriteToRoom</actions_list>')
		table.insert(x, '</item>')
	end
	if (#(apps or {}) == 0) then
		table.insert(x, '<item>' .. XMLTag('title', 'No apps reported') .. XMLTag('subtitle', 'Is the bridge online?') .. '</item>')
	end
	table.insert(x, '</List>')
	return table.concat(x)
end

-------------------------------------------------------------------------------
-- Launching
-------------------------------------------------------------------------------

function ShieldMac()
	local mac = trim(Properties['Shield MAC Address']):gsub('[^%x]', '')
	if (#mac ~= 12) then return nil end
	return mac
end

function WakeShield()
	local mac = ShieldMac()
	if (mac) then
		dbg('WOL to ' .. mac)
		pcall(function() C4:SendWOL(mac) end)
	end
	BridgeRequest('POST', '/api/wake', {}, nil)
end

-- Room variable 1000 holds the proxy device id of the room's current source.
function RoomCurrentDevice(roomId)
	local ok, v = pcall(function() return C4:GetDeviceVariable(roomId, 1000) end)
	if (ok) then return tonumber(v) end
	return nil
end

-- Selects this driver as the room's video source, unless the room is already
-- on it. Re-selecting an active source makes the room re-run its power-on
-- sequence, which flips displays that only have an IR power toggle.
function SelectInRoom(roomId)
	roomId = tonumber(roomId)
	if (not roomId or roomId == 0) then return end
	local mode = Properties['Select Room Source'] or 'If not already selected'
	if (mode == 'Never') then return end
	local proxyId = C4:GetProxyDevices()
	if (mode ~= 'Always') then
		local current = RoomCurrentDevice(roomId)
		if (current and (current == proxyId or current == C4:GetDeviceID())) then
			dbg('room ' .. roomId .. ' already on this source; not re-selecting')
			return
		end
	end
	dbg('SELECT_VIDEO_DEVICE in room ' .. roomId .. ' -> ' .. tostring(proxyId))
	C4:SendToDevice(roomId, 'SELECT_VIDEO_DEVICE', { deviceid = proxyId })
end

-- Core launch path used by Navigator actions, favorites and programming.
-- target = { id = <watch next row id> } | { package = ... } | { url = ... } | { intentUri = ... }
-- display = { title, subtitle, art } for Now Playing / variables.
function LaunchOnShield(target, display, roomId)
	SelectInRoom(roomId)
	if ((Properties['Wake on Select'] or 'On') == 'On') then
		WakeShield()
	end
	local delay = tonumber(Properties['Launch Delay (ms)']) or 0

	local function go()
		BridgeRequest('POST', '/api/launch', target, function(err, data)
			if (err) then
				print('Shield Bridge: launch failed: ' .. tostring(err))
				C4:UpdateProperty('Bridge Status', 'Launch failed: ' .. tostring(err))
				return
			end
			dbg('launch ok: ' .. tostring(type(data) == 'table' and data.message or data))
		end)
	end

	if (delay > 0) then
		KillTimer('launch')
		Timer.launch = C4:SetTimer(delay, function(timer)
			Timer.launch = nil
			go()
		end)
	else
		go()
	end

	if (display) then
		Bridge.lastLaunched = display
		C4:SetVariable('LAST_LAUNCHED_TITLE', display.title or '')
		C4:SetVariable('LAST_LAUNCHED_APP', display.app or '')
		UpdateMediaInfo()
		UpdateQueue()
		UpdateDashboard()
		C4:FireEvent('Item Launched')
	end
end

function DisplayForItem(item)
	return {
		title = item.title or '',
		subtitle = ItemSubtitle(item),
		app = item.app or '',
		art = item.art,
		id = item.id,
	}
end

function LaunchItemById(id, roomId)
	local item = Bridge.itemsById[tostring(id)]
	if (item) then
		LaunchOnShield({ id = tonumber(item.id) or item.id }, DisplayForItem(item), roomId)
		return true
	end
	-- Unknown id: ask the bridge anyway, it keeps its own cache.
	LaunchOnShield({ id = tonumber(id) or id }, { title = 'Item ' .. tostring(id), app = '' }, roomId)
	return false
end

function LaunchPackage(pkg, roomId)
	local app = Bridge.appsByPackage[pkg]
	LaunchOnShield({ package = pkg }, { title = (app and app.label) or pkg, app = (app and app.label) or pkg, art = app and app.icon }, roomId)
end

-- Launches the most recently watched CONTINUE row. Refreshes the list first so
-- a keypad press always resumes what was really watched last.
function ResumeLatest(roomId)
	FetchContinue(function(err, items)
		local pick = nil
		for _, item in ipairs(items or {}) do
			if (item.watchNextType == 'CONTINUE') then pick = item break end
		end
		pick = pick or (items or {})[1]
		if (not pick) then
			print('Shield Bridge: nothing to resume' .. (err and (' (' .. err .. ')') or ''))
			return
		end
		LaunchOnShield({ id = tonumber(pick.id) or pick.id }, DisplayForItem(pick), roomId)
	end)
end

-------------------------------------------------------------------------------
-- Remote / transport forwarding to the Shield's own driver
-------------------------------------------------------------------------------

function ResolveShieldDevice()
	if (ShieldDeviceId) then return ShieldDeviceId end
	local ok, id = pcall(function() return C4:GetBoundProviderDevice(C4:GetProxyDevices(), VIDEO_IN_BINDING) end)
	if (ok and id and id ~= 0) then ShieldDeviceId = id end
	return ShieldDeviceId
end

FORWARDED_COMMANDS = {}
do
	local base = {
		'PLAY', 'PAUSE', 'STOP', 'SKIP_FWD', 'SKIP_REV', 'SCAN_FWD', 'SCAN_REV', 'RECORD',
		'UP', 'DOWN', 'LEFT', 'RIGHT', 'ENTER', 'CANCEL', 'MENU', 'INFO', 'GUIDE', 'RECALL',
		'PAGE_UP', 'PAGE_DOWN', 'CH_UP', 'CH_DOWN', 'STAR', 'POUND', 'DVR', 'TV_VIDEO',
		'PROGRAM_A', 'PROGRAM_B', 'PROGRAM_C', 'PROGRAM_D', 'CLOSED_CAPTIONED',
		'NUMBER_0', 'NUMBER_1', 'NUMBER_2', 'NUMBER_3', 'NUMBER_4', 'NUMBER_5', 'NUMBER_6', 'NUMBER_7', 'NUMBER_8', 'NUMBER_9',
		'CUSTOM_1', 'CUSTOM_2', 'CUSTOM_3', 'PLAYPAUSE',
	}
	for _, c in ipairs(base) do
		FORWARDED_COMMANDS[c] = true
		FORWARDED_COMMANDS['START_' .. c] = true
		FORWARDED_COMMANDS['STOP_' .. c] = true
		FORWARDED_COMMANDS['PULSE_' .. c] = true
		FORWARDED_COMMANDS['END_' .. c] = true
	end
end

function ForwardToShield(strCommand, tParams)
	if ((Properties['Forward Remote Commands'] or 'To device on Video In') ~= 'To device on Video In') then
		return false
	end
	local target = ResolveShieldDevice()
	if (not target) then
		dbg('no device bound to Video In; cannot forward ' .. strCommand)
		return false
	end
	local params = {}
	for k, v in pairs(tParams or {}) do
		if (k ~= 'NAVID' and k ~= 'SEQ' and k ~= 'ROOMID' and k ~= 'ARGS') then params[k] = v end
	end
	dbg('forward ' .. strCommand .. ' -> device ' .. tostring(target))
	C4:SendToDevice(target, strCommand, params)
	return true
end

-------------------------------------------------------------------------------
-- Navigator plumbing (Media Service Proxy)
-------------------------------------------------------------------------------

function DataReceived(idBinding, navId, seq, data)
	C4:SendToProxy(idBinding, 'DATA_RECEIVED', { NAVID = navId, SEQ = seq, DATA = data or '' })
end

function DataReceivedError(idBinding, navId, seq, msg)
	C4:SendToProxy(idBinding, 'DATA_RECEIVED', { NAVID = navId, SEQ = seq, DATA = '', ERROR = msg or 'error' })
end

function SendEvent(idBinding, navId, roomId, name, args)
	C4:SendToProxy(idBinding, 'SEND_EVENT', { NAVID = navId, ROOMS = roomId, NAME = name, EVTARGS = args or '' }, 'COMMAND')
end

function UpdateMediaInfo()
	local last = Bridge.lastLaunched
	local args = {
		TITLE = (last and last.title) or 'Continue Watching',
		ALBUM = (last and last.subtitle) or '',
		ARTIST = (last and last.app) or 'Shield',
		GENRE = '',
	}
	if (last and last.art and last.art ~= '') then
		args.IMAGEURL = C4:Base64Encode(last.art)
	end
	C4:SendToProxy(MSP_PROXY, 'UPDATE_MEDIA_INFO', args, 'COMMAND', true)
end

function UpdateDashboard(navId, roomId)
	SendEvent(MSP_PROXY, navId, roomId, 'DashboardChanged', '<Items>SkipRev Play Pause SkipFwd Stop</Items>')
end

function UpdateQueue(navId, roomId)
	local x = {}
	local last = Bridge.lastLaunched
	if (last) then
		table.insert(x, HeaderXml('Now Playing'))
		table.insert(x, '<item>' .. XMLTag('title', last.title) .. XMLTag('subtitle', last.subtitle or '') ..
			((last.art and last.art ~= '') and ('<image_list width="300" height="169">' .. XMLEncode(last.art) .. '</image_list>') or '') ..
			(last.id and XMLTag('id', last.id) or '') ..
			'</item>')
	end
	local shown = 0
	for _, item in ipairs(Bridge.items) do
		if (item.watchNextType == 'CONTINUE' and (not last or tostring(item.id) ~= tostring(last.id))) then
			if (shown == 0) then table.insert(x, HeaderXml('Continue Watching')) end
			table.insert(x, ItemXml(item))
			shown = shown + 1
			if (shown >= 8) then break end
		end
	end
	local args = '<List>' .. table.concat(x) .. '</List><NowPlayingIndex>' .. (last and 1 or 0) .. '</NowPlayingIndex>'
	SendEvent(MSP_PROXY, navId, roomId, 'QueueChanged', args)
end

-- Handlers for commands arriving from the proxy. Each receives (tParams, args).
RFP = {}

function RFP.GetContinue(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	FetchContinue(function(err, items)
		if (err and #(items or {}) == 0) then
			DataReceivedError(idBinding, navId, seq, 'Shield Bridge unreachable: ' .. tostring(err))
			return
		end
		local notice = err and 'Bridge offline, showing last known list' or nil
		DataReceived(idBinding, navId, seq, BuildContinueList(items, notice))
	end)
end

function RFP.GetApps(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	FetchApps(function(err, apps)
		if (err and #(apps or {}) == 0) then
			DataReceivedError(idBinding, navId, seq, 'Shield Bridge unreachable: ' .. tostring(err))
			return
		end
		DataReceived(idBinding, navId, seq, BuildAppsList(apps))
	end)
end

function AfterLaunchScreen()
	if ((Properties['After Launch'] or 'Go to Now Playing') == 'Go to Now Playing') then
		return '<NextScreen>#nowplaying</NextScreen>'
	end
	return ''
end

function RFP.LaunchItem(tParams, args, idBinding)
	local id = args.id
	if (not id or id == '') then
		DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, 'No item selected')
		return
	end
	LaunchItemById(id, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, AfterLaunchScreen())
end

function RFP.LaunchApp(tParams, args, idBinding)
	local pkg = args.id
	if (not pkg or pkg == '') then
		DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, 'No app selected')
		return
	end
	LaunchPackage(pkg, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, AfterLaunchScreen())
end

-- Room favorite creation: Navigator asks us to describe the selected item.
function RFP.FavoriteToRoom(tParams, args, idBinding)
	PersistData.favorites = PersistData.favorites or {}
	local screen = args.screenId or ''
	local id = args.id or ''
	local fav = nil
	if (screen == 'AppsScreen') then
		local app = Bridge.appsByPackage[id]
		if (app) then
			fav = { kind = 'package', package = id, title = app.label or id, art = app.icon }
		end
	else
		local item = Bridge.itemsById[tostring(id)]
		if (item) then
			-- Store the deep link itself so the favorite survives the row leaving Watch Next.
			fav = { kind = 'intent', intentUri = item.intentUri, package = item.package,
				title = item.title or '', subtitle = ItemSubtitle(item), app = item.app, art = item.art }
		end
	end
	if (not fav) then
		DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, 'Nothing selected to favorite')
		return
	end
	local favId = tostring(os.time()) .. '_' .. tostring(id):gsub('[^%w]', '')
	PersistData.favorites[favId] = fav
	local x = '<FavoriteResponse>' .. XMLTag('Title', fav.title) ..
		((fav.art and fav.art ~= '') and ('<ImageUrl width="512" height="512">' .. XMLEncode(fav.art) .. '</ImageUrl>') or '') ..
		'<Context>' .. XMLTag('favoriteId', favId) .. '</Context></FavoriteResponse>'
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, x)
end

function RFP.jumpToFavorite(tParams, args, idBinding)
	local favId = args.id or args.favoriteId
	local fav = PersistData.favorites and PersistData.favorites[tostring(favId)]
	if (not fav) then
		print('Shield Bridge: unknown favorite ' .. tostring(favId))
		return
	end
	local display = { title = fav.title, subtitle = fav.subtitle, app = fav.app or fav.title, art = fav.art }
	if (fav.kind == 'package') then
		LaunchOnShield({ package = fav.package }, display, tParams.ROOMID)
	elseif (fav.intentUri and fav.intentUri ~= '') then
		LaunchOnShield({ intentUri = fav.intentUri }, display, tParams.ROOMID)
	else
		LaunchOnShield({ package = fav.package }, display, tParams.ROOMID)
	end
end

function RFP.GetDashboard(tParams, args, idBinding)
	UpdateDashboard(tParams.NAVID, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
end

function RFP.GetQueue(tParams, args, idBinding)
	UpdateQueue(tParams.NAVID, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
end

function RFP.DEVICE_SELECTED(tParams, args, idBinding)
	if ((Properties['Wake on Select'] or 'On') == 'On') then WakeShield() end
	FetchContinue(nil)
	UpdateMediaInfo()
	UpdateDashboard()
end

RFP.ON = RFP.DEVICE_SELECTED

function RFP.DEVICE_DESELECTED(tParams, args, idBinding) end
function RFP.OFF(tParams, args, idBinding) end
function RFP.SET_INPUT(tParams, args, idBinding) end
function RFP.CONNECT_OUTPUT(tParams, args, idBinding) end
function RFP.DISCONNECT_OUTPUT(tParams, args, idBinding) end
function RFP.INPUT_OUTPUT_CHANGED(tParams, args, idBinding) end
function RFP.DESTROY_NAVIGATOR(tParams, args, idBinding) end
function RFP.DESTROY_NAV(tParams, args, idBinding) end
function RFP.SettingChanged(tParams, args, idBinding) end

function ParseArgs(tParams)
	local args = {}
	if (tParams.ARGS) then
		local ok, parsed = pcall(function() return C4:ParseXml(tParams.ARGS) end)
		if (ok and parsed and parsed.ChildNodes) then
			for _, node in pairs(parsed.ChildNodes) do
				if (node.Attributes and node.Attributes.name) then
					args[node.Attributes.name] = node.Value
				end
			end
		end
	end
	return args
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	strCommand = strCommand or ''
	tParams = tParams or {}
	local args = ParseArgs(tParams)
	tParams.ARGS = nil
	if (DEBUGPRINT) then
		local out = { '--- ReceivedFromProxy ' .. tostring(idBinding) .. ' ' .. strCommand }
		for k, v in pairs(tParams) do table.insert(out, '  ' .. tostring(k) .. ' = ' .. tostring(v)) end
		for k, v in pairs(args) do table.insert(out, '  arg ' .. tostring(k) .. ' = ' .. tostring(v)) end
		print(table.concat(out, '\n'))
	end
	if (idBinding ~= MSP_PROXY) then return end

	local handler = RFP[strCommand]
	if (handler) then
		local ok, err = pcall(handler, tParams, args, idBinding)
		if (not ok) then
			print('Shield Bridge: error in ' .. strCommand .. ': ' .. tostring(err))
			if (tParams.NAVID and tParams.SEQ) then
				DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, tostring(err))
			end
		end
		return
	end

	if (FORWARDED_COMMANDS[strCommand]) then
		ForwardToShield(strCommand, tParams)
		return
	end

	dbg('unhandled proxy command ' .. strCommand)
	if (tParams.NAVID and tParams.SEQ) then
		DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
	end
end

-------------------------------------------------------------------------------
-- Programming: commands, actions, custom selects
-------------------------------------------------------------------------------

EC = {}

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	if (strCommand == 'LUA_ACTION' and tParams.ACTION) then
		strCommand = tParams.ACTION
		tParams.ACTION = nil
	end
	local key = strCommand:gsub('%s+', '_')
	local fn = EC[key]
	if (not fn) then
		dbg('unhandled command ' .. strCommand)
		return
	end
	local ok, err = pcall(fn, tParams)
	if (not ok) then print('Shield Bridge: command ' .. strCommand .. ' failed: ' .. tostring(err)) end
end

function EC.Resume_Latest(tParams)
	ResumeLatest(tParams.Room)
end

function EC.Launch_Item(tParams)
	local id = tParams.Item
	if (id and id ~= '') then LaunchItemById(id, tParams.Room) end
end

function EC.Launch_App(tParams)
	local pkg = tParams.App
	if (pkg and pkg ~= '') then LaunchPackage(pkg, tParams.Room) end
end

function EC.Launch_URL(tParams)
	local url = trim(tParams.URL)
	if (url == '') then return end
	LaunchOnShield({ url = url }, { title = url, app = '' }, tParams.Room)
end

function EC.Wake_Shield(tParams)
	WakeShield()
end

function EC.Refresh(tParams)
	FetchContinue(nil)
	FetchApps(nil)
end

function EC.Test_Connection(tParams)
	BridgeRequest('GET', '/api/status', nil, function(err, data)
		if (err) then
			print('Shield Bridge: NOT reachable: ' .. tostring(err))
			return
		end
		local perms = (type(data) == 'table' and data.permissions) or {}
		print(string.format('Shield Bridge %s on %s: TV listings=%s, overlay=%s, watch next rows=%s',
			tostring(data.version), tostring(data.device), tostring(perms.readTvListings),
			tostring(perms.displayOverOtherApps), tostring(data.watchNextCount)))
		if (perms.readTvListings == false) then
			print('  -> grant the TV listings permission in the Shield Bridge app or Continue Watching stays empty')
		end
		if (perms.displayOverOtherApps == false) then
			print('  -> allow "Display over other apps" or launches may be blocked while the app is in the background')
		end
	end)
	FetchContinue(nil)
	FetchApps(nil)
end

-- CUSTOM_SELECT providers for programming parameters. These are synchronous
-- so they serve the cache that the refresh timer keeps warm.
function ContinueSelect(currentValue)
	local out = {}
	for _, item in ipairs(Bridge.items) do
		local label = (item.title or '?')
		local sub = ItemSubtitle(item)
		if (sub ~= '') then label = label .. '  (' .. sub .. ')' end
		table.insert(out, { text = label, value = tostring(item.id) })
	end
	if (#out == 0) then
		table.insert(out, { text = '(no items yet - run Refresh in Actions)', value = '' })
	end
	return out
end

function AppSelect(currentValue)
	local out = {}
	for _, app in ipairs(Bridge.apps) do
		table.insert(out, { text = app.label or app.package, value = app.package })
	end
	if (#out == 0) then
		table.insert(out, { text = '(no apps yet - run Refresh in Actions)', value = '' })
	end
	return out
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function StartRefreshTimer()
	KillTimer('refresh')
	local secs = tonumber(Properties['Refresh Interval (s)']) or 60
	if (secs <= 0) then return end
	Timer.refresh = C4:SetTimer(secs * 1000, function(timer)
		FetchContinue(nil)
	end, true)
end

OPC = {}

function OPC.Debug_Mode(value)
	DEBUGPRINT = (value == 'On')
end

function OPC.Bridge_Address(value)
	Bridge.online = nil
	if (trim(value) ~= '') then
		FetchContinue(nil)
		FetchApps(nil)
	end
end

function OPC.Refresh_Interval_s(value)
	StartRefreshTimer()
end

function OPC.Shield_MAC_Address(value)
	local cleaned = trim(value)
	if (cleaned ~= '' and not ShieldMac()) then
		C4:UpdateProperty('Bridge Status', 'MAC address should look like AA:BB:CC:DD:EE:FF')
	end
end

function OnPropertyChanged(strProperty)
	local value = Properties[strProperty]
	if (value == nil) then value = '' end
	local key = strProperty:gsub('[%s%(%)]+', '_'):gsub('_+$', '')
	local fn = OPC[key]
	if (fn) then
		local ok, err = pcall(fn, value)
		if (not ok) then print('Shield Bridge: property ' .. strProperty .. ' failed: ' .. tostring(err)) end
	end
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
	if (idBinding == VIDEO_IN_BINDING) then
		ShieldDeviceId = bIsBound and otherDeviceId or nil
		dbg('Video In now bound to ' .. tostring(ShieldDeviceId))
	end
end

function OnDriverInit()
end

function OnDriverLateInit()
	KillAllTimers()
	pcall(function() C4:urlSetTimeout(8) end)
	C4:AddVariable('LAST_LAUNCHED_TITLE', '', 'STRING', true, false)
	C4:AddVariable('LAST_LAUNCHED_APP', '', 'STRING', true, false)
	C4:AddVariable('BRIDGE_ONLINE', 'false', 'STRING', true, false)
	C4:UpdateProperty('Driver Version', DRIVER_VERSION)
	for name, _ in pairs(Properties) do
		OnPropertyChanged(name)
	end
	StartRefreshTimer()
	if (BridgeBaseUrl()) then
		BridgeRequest('GET', '/api/status', nil, nil)
	end
end

function OnDriverDestroyed()
	KillAllTimers()
end
