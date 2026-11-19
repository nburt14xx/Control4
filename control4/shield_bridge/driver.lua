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

DRIVER_VERSION = "0.4.0"

MSP_PROXY = 5001          -- media_service proxy binding: browse, search, poster Now Playing
REMOTE_PROXY = 5002       -- media_player proxy binding: Control4's standard remote screen

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

function URLEncode(s)
	if (s == nil) then return '' end
	s = tostring(s)
	s = s:gsub('([^%w%-%_%.%~])', function (c) return string.format('%%%02X', string.byte(c)) end)
	return s
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
			if (type(data) == 'table') then
				if (data.error) then msg = msg .. ': ' .. tostring(data.error)
				elseif (data.message) then msg = msg .. ': ' .. tostring(data.message) end
			end
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

-- Device id of the proxy on one of this driver's proxy bindings. With two
-- proxies, C4:GetProxyDevices() is not specific enough, so ask the binding.
ProxyIds = ProxyIds or {}
function ProxyIdFor(binding)
	if (ProxyIds[binding]) then return ProxyIds[binding] end
	local ok, t = pcall(function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding) end)
	local id = nil
	if (ok and type(t) == 'table') then id = tonumber((next(t))) end
	if (not id and binding == MSP_PROXY) then
		id = tonumber(tostring(C4:GetProxyDevices() or ''):match('(%d+)'))
	end
	ProxyIds[binding] = id
	return id
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
-- Shield Bridge is the room's Shield source. Launching from Navigator needs no
-- room command (the user is already on this source); "Select Shield Bridge"
-- exists for keypad or scene launches that should also turn the room on. The
-- command is skipped when the room is already on this source.
function SelectInRoom(roomId)
	roomId = tonumber(roomId)
	if (not roomId or roomId == 0) then return end
	if ((Properties['Select Room Source'] or 'Never') ~= 'Select Shield Bridge') then return end
	local targetId = ProxyIdFor(MSP_PROXY)
	local current = RoomCurrentDevice(roomId)
	if (current and current == targetId) then
		dbg('room ' .. roomId .. ' already on Shield Bridge; not re-selecting')
		return
	end
	dbg('SELECT_VIDEO_DEVICE in room ' .. roomId .. ' -> ' .. tostring(targetId))
	C4:SendToDevice(roomId, 'SELECT_VIDEO_DEVICE', { deviceid = targetId })
end

-- Core launch path used by Navigator actions, favorites and programming.
-- target = { id = <watch next row id> } | { package = ... } | { url = ... } | { intentUri = ... }
-- display = { title, subtitle, art } for Now Playing / variables.
function LaunchOnShield(target, display, roomId, onResult)
	SelectInRoom(roomId)
	if ((Properties['Wake on Select'] or 'On') == 'On') then
		WakeShield()
	end
	local delay = tonumber(Properties['Launch Delay (ms)']) or 0

	local function go()
		local qs = {}
		for _, k in ipairs({ 'id', 'package', 'url', 'intentUri' }) do
			if (target[k] ~= nil and target[k] ~= '') then
				table.insert(qs, k .. '=' .. URLEncode(tostring(target[k])))
			end
		end
		local path = '/api/launch'
		if (#qs > 0) then path = path .. '?' .. table.concat(qs, '&') end
		BridgeRequest('POST', path, target, function(err, data)
			if (err) then
				print('Shield Bridge: launch failed: ' .. tostring(err))
				C4:UpdateProperty('Bridge Status', 'Launch failed: ' .. tostring(err))
				if (onResult) then onResult(false, err) end
				return
			end
			dbg('launch ok: ' .. tostring(type(data) == 'table' and data.message or data))
			if (onResult) then onResult(true) end
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
	local display = item and DisplayForItem(item) or { title = 'Item ' .. tostring(id), app = '' }
	LaunchOnShield({ id = tonumber(id) or id }, display, roomId, function(ok, err)
		if (ok) then return end
		-- The app refused the resume deep link. Open the app itself so the user
		-- is not left on a black input; the room is already selected and awake.
		if (item and item.package and item.package ~= '') then
			print('Shield Bridge: resume link refused (' .. tostring(err) .. '); opening ' .. tostring(item.app or item.package) .. ' instead')
			LaunchOnShield({ package = item.package }, display, roomId)
		end
	end)
	return item ~= nil
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

-- The driver that really controls the Shield (IP, IR or CEC). It can live in
-- any room; nothing is wired between it and this driver. The numeric override
-- wins over the picker.
function ResolveShieldDevice()
	local id = tonumber(trim(Properties['Shield Control Device ID']))
	if (not id or id <= 0) then
		id = tonumber(tostring(Properties['Shield Control Device'] or ''):match('(%d+)'))
	end
	if (not id or id <= 0) then return nil end
	-- never relay to ourselves: that would loop
	if (id == ProxyIdFor(MSP_PROXY) or id == ProxyIdFor(REMOTE_PROXY) or id == C4:GetDeviceID()) then return nil end
	return id
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
	if ((Properties['Forward Remote Commands'] or 'On') == 'Off') then
		return false
	end
	local target = ResolveShieldDevice()
	if (not target) then
		dbg('no Shield Control Device chosen; cannot relay ' .. strCommand)
		return false
	end
	local params = {}
	for k, v in pairs(tParams or {}) do
		if (k ~= 'NAVID' and k ~= 'SEQ' and k ~= 'ROOMID' and k ~= 'ARGS') then params[k] = v end
	end
	dbg('relay ' .. strCommand .. ' -> device ' .. tostring(target))
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
	SendEvent(MSP_PROXY, navId, roomId, 'DashboardChanged', '<Items>ScanRev Play Pause ScanFwd SkipFwd</Items>')
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

-- What Navigator does after a launch. "Switch to Remote" moves the room to
-- this driver's standard remote screen; both screens share one video path to
-- the TV/AVR, so it is a source change, not a power-up.
function AfterLaunchScreen(roomId)
	local mode = Properties['After Launch'] or 'Go to Now Playing'
	if (mode == 'Switch to Remote') then
		roomId = tonumber(roomId)
		local remoteId = ProxyIdFor(REMOTE_PROXY)
		if (roomId and roomId ~= 0 and remoteId) then
			if (RoomCurrentDevice(roomId) ~= remoteId) then
				dbg('switching room ' .. roomId .. ' to the remote screen ' .. remoteId)
				C4:SendToDevice(roomId, 'SELECT_VIDEO_DEVICE', { deviceid = remoteId })
			end
			return ''
		end
		return '<NextScreen>#nowplaying</NextScreen>'
	end
	if (mode == 'Go to Now Playing') then
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
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, AfterLaunchScreen(tParams.ROOMID))
end

function RFP.LaunchApp(tParams, args, idBinding)
	local pkg = args.id
	if (not pkg or pkg == '') then
		DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, 'No app selected')
		return
	end
	LaunchPackage(pkg, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, AfterLaunchScreen(tParams.ROOMID))
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

-- Builds the launch target for a search. "global" uses Android TV's system-wide
-- search (what the Shield's own mic search drives, minus the voice); the per-app
-- targets open that app's search results page. Results appear on the TV; the
-- Shield exposes no way to return them to Control4.
function BuildSearchTarget(query, target)
	query = trim(query)
	if (query == '') then return nil end
	local tl = tostring(target or 'global'):lower()
	if (tl == 'netflix') then
		return { url = 'https://www.netflix.com/search?q=' .. URLEncode(query) }, 'Netflix'
	elseif (tl == 'youtube') then
		return { url = 'https://www.youtube.com/results?search_query=' .. URLEncode(query) }, 'YouTube'
	else
		local intentUri = 'intent:#Intent;action=android.search.action.GLOBAL_SEARCH;S.query=' .. URLEncode(query) .. ';end'
		return { intentUri = intentUri }, 'all apps'
	end
end

function DoSearch(query, target, roomId)
	local t, label = BuildSearchTarget(query, target)
	if (not t) then
		print('Shield Bridge: empty search query')
		return false
	end
	dbg('search "' .. query .. '" in ' .. label)
	-- Search is a lookup, not a source change: never select the room or touch
	-- power (roomId is intentionally dropped). Results appear on the TV.
	LaunchOnShield(t, { title = 'Search: ' .. query, app = 'Search' }, nil)
	return true
end

-- Opens the Shield's own home screen (its native UI) with no room or power
-- command, so it never disturbs a projector on an IR power toggle.
function RFP.HOME(tParams, args, idBinding)
	local homeIntent = 'intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.HOME;end'
	BridgeRequest('POST', '/api/launch?intentUri=' .. URLEncode(homeIntent), { intentUri = homeIntent }, function(err)
		if (err) then print('Shield Bridge: Home failed: ' .. tostring(err)) end
	end)
end

function RFP.GetSearch(tParams, args, idBinding)
	local q = XMLEncode(PersistData.searchQuery or '')
	local tgt = PersistData.searchTarget or 'global'
	local xml = '<Settings><SearchQuery>' .. q .. '</SearchQuery><SearchTarget>' .. tgt .. '</SearchTarget></Settings>'
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, xml)
end

function RFP.SearchGo(tParams, args, idBinding)
	local q = PersistData.searchQuery or ''
	if (trim(q) == '') then
		-- nothing typed yet: stay on the screen
		DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
		return
	end
	DoSearch(q, PersistData.searchTarget or 'global', tParams.ROOMID)
	-- stay on the Search screen; results show on the TV
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
end

-- On-screen remote: a list of keys. Each relays the standard Control4 command
-- to the Shield Control Device; Home goes through the bridge app instead, so it
-- works even with no control device chosen.
REMOTE_KEYS = {
	{ 'UP', 'Up', 'nav_up' }, { 'DOWN', 'Down', 'nav_down' }, { 'LEFT', 'Left', 'nav_left' },
	{ 'RIGHT', 'Right', 'nav_right' }, { 'ENTER', 'OK / Select', 'nav_ok' }, { 'CANCEL', 'Back', 'nav_back' },
	{ 'HOME', 'Home', 'nav_home' }, { 'PLAY', 'Play', 'nav_play' }, { 'PAUSE', 'Pause', 'nav_pause' },
	{ 'SCAN_REV', 'Rewind', 'nav_rew' }, { 'SCAN_FWD', 'Fast Forward', 'nav_ff' },
	{ 'SKIP_REV', 'Previous', 'nav_left' }, { 'SKIP_FWD', 'Next', 'nav_right' },
	{ 'MENU', 'Menu', 'nav_ok' }, { 'INFO', 'Info', 'nav_ok' },
}

function RFP.GetRemote(tParams, args, idBinding)
	local x = { '<List>' }
	if (not ResolveShieldDevice()) then
		table.insert(x, HeaderXml('Choose a Shield Control Device in Composer to enable these keys'))
	end
	for _, k in ipairs(REMOTE_KEYS) do
		local icon = 'controller://driver/shield_bridge/icons/' .. k[3] .. '/' .. k[3] .. '_140.png'
		table.insert(x, '<item>' .. XMLTag('id', k[1]) .. XMLTag('title', k[2]) ..
			'<image_list width="140" height="140">' .. icon .. '</image_list>' ..
			'<default_action>RemoteKey</default_action></item>')
	end
	table.insert(x, '</List>')
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, table.concat(x))
end

function RFP.RemoteKey(tParams, args, idBinding)
	local key = tostring(args.id or '')
	if (key == 'HOME') then
		RFP.HOME(tParams, args, idBinding)
	elseif (FORWARDED_COMMANDS[key]) then
		ForwardToShield(key, {})
	end
	-- empty reply keeps the remote on screen for the next press
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
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
function RFP.SettingChanged(tParams, args, idBinding)
	local prop = args.PropertyName or args.propertyName
	local value = args.Value or args.value
	if (prop == 'SearchQuery') then
		PersistData.searchQuery = value or ''
	elseif (prop == 'SearchTarget') then
		PersistData.searchTarget = value or 'global'
	end
end

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

-- Commands from the standard remote screen (media_player proxy). Keys are
-- relayed to the Shield Control Device exactly like the browse screen's.
function HandleRemoteProxy(strCommand, tParams)
	if (strCommand == 'ON' or strCommand == 'DEVICE_SELECTED') then
		if ((Properties['Wake on Select'] or 'Off') == 'On') then WakeShield() end
		return
	end
	if (strCommand == 'OFF' or strCommand == 'DEVICE_DESELECTED') then return end
	if (strCommand == 'HOME') then
		RFP.HOME(tParams, {}, REMOTE_PROXY)
		return
	end
	if (FORWARDED_COMMANDS[strCommand]) then
		ForwardToShield(strCommand, tParams)
		return
	end
	dbg('remote screen: unhandled ' .. strCommand)
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
	if (idBinding == REMOTE_PROXY) then
		HandleRemoteProxy(strCommand, tParams)
		return
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
-- In-Control4 search (Streaming Availability API by Movie of the Night)
--
-- The streaming apps expose no search API, so titles come from a public
-- availability database scoped to one country. Each result lists which of the
-- apps installed on the Shield carry it; tapping plays it there, resuming from
-- Continue Watching when the title is already in progress.
-------------------------------------------------------------------------------

SEARCH_CACHE_SECS = 600

-- Android TV packages for the API's service ids. Only used to pick which
-- installed app opens a result; anything missing here is matched by name
-- against the apps the Shield reports.
SERVICE_PACKAGES = {
	netflix = { 'com.netflix.ninja' },
	prime = { 'com.amazon.amazonvideo.livingroom' },
	disney = { 'com.disney.disneyplus' },
	hbo = { 'com.wbd.stream', 'com.hbo.hbonow' },
	hulu = { 'com.hulu.livingroomplus', 'com.hulu.plus' },
	peacock = { 'com.peacocktv.peacockandroid' },
	paramount = { 'com.cbs.ott', 'com.cbs.app' },
	apple = { 'com.apple.atve.androidtv.appletv' },
	starz = { 'com.bydeluxe.d3.android.program.starz' },
	tubi = { 'com.tubitv' },
	plutotv = { 'tv.pluto.android' },
	crunchyroll = { 'com.crunchyroll.crunchyroid' },
	mubi = { 'com.mubi' },
}

-- Other names a service's app may carry on the Shield (normalised form).
SERVICE_ALIASES = {
	hbo = { 'max', 'hbomax' },
	apple = { 'appletv' },
	prime = { 'primevideo', 'amazonprimevideo' },
	disney = { 'disney' },
	paramount = { 'paramount' },
	plutotv = { 'pluto', 'plutotv' },
}

Finder = Finder or { cache = {}, cacheOrder = {}, shows = {}, showCount = 0, lastQuery = {}, lastShow = {} }

-- "Disney+", "Disney Plus" and "disney" all become "disney".
function NormName(s)
	s = tostring(s or ''):lower():gsub('%+', ''):gsub('[^%w]', '')
	s = s:gsub('plus$', '')
	return s
end

function SearchCountry()
	local c = trim(Properties['Search Country']):lower():gsub('[^a-z]', '')
	if (#c ~= 2) then c = 'us' end
	return c
end

function SearchApiConfig()
	local key = trim(Properties['Search API Key'])
	if (key == '') then return nil end
	if ((Properties['Search API Service'] or '') == 'RapidAPI') then
		return {
			base = 'https://streaming-availability.p.rapidapi.com',
			headers = { ['X-RapidAPI-Key'] = key, ['X-RapidAPI-Host'] = 'streaming-availability.p.rapidapi.com' },
		}
	end
	return { base = 'https://api.movieofthenight.com/v4', headers = { ['X-API-Key'] = key } }
end

-- callback(err, data, code). err is 'no_key', 'key_rejected', 'quota' or text.
function SearchApiGet(path, callback)
	local cfg = SearchApiConfig()
	if (not cfg) then
		callback('no_key')
		return
	end
	local url = cfg.base .. path
	dbg('SEARCH GET ' .. url)
	local function handle(ticketId, strData, responseCode, tHeaders, strError)
		strData = strData or ''
		local code = tonumber(responseCode) or 0
		if (strError and strError ~= '') then
			callback('search service unreachable: ' .. tostring(strError), nil, code)
			return
		end
		local data, derr = nil, nil
		if (strData:match('^%s*[%[{]')) then data, derr = JSON.decode(strData) end
		if (code == 401 or code == 403) then callback('key_rejected', data, code) return end
		if (code == 429) then callback('quota', data, code) return end
		if (code < 200 or code >= 300) then
			local msg = 'search service HTTP ' .. code
			if (type(data) == 'table' and data.message) then msg = msg .. ': ' .. tostring(data.message) end
			callback(msg, data, code)
			return
		end
		if (data == nil) then
			callback('bad reply from search service: ' .. tostring(derr), nil, code)
			return
		end
		callback(nil, data, code)
	end
	local ok, e = pcall(function() C4:urlGet(url, cfg.headers, false, handle) end)
	if (not ok) then callback('search request failed: ' .. tostring(e)) end
end

function SearchErrorText(err)
	if (err == 'no_key') then return 'Add a Search API Key in Composer to see results here' end
	if (err == 'key_rejected') then return 'The search service rejected the API key; check it in Composer' end
	if (err == 'quota') then return 'Search limit reached for now; try again later' end
	return tostring(err)
end

function RememberShows(shows)
	if (Finder.showCount > 400) then
		-- keep memory bounded: start over from what is still cached
		Finder.shows, Finder.showCount = {}, 0
		for _, key in ipairs(Finder.cacheOrder) do
			for _, s in ipairs(Finder.cache[key].shows) do
				if (s.id and not Finder.shows[tostring(s.id)]) then
					Finder.shows[tostring(s.id)] = s
					Finder.showCount = Finder.showCount + 1
				end
			end
		end
	end
	for _, s in ipairs(shows) do
		if (s.id and not Finder.shows[tostring(s.id)]) then Finder.showCount = Finder.showCount + 1 end
		if (s.id) then Finder.shows[tostring(s.id)] = s end
	end
end

-- callback(err, shows). Results are cached per country/type/query to spare
-- the API quota, since Navigator re-requests a list every time it is shown.
function FinderSearch(query, filter, callback)
	query = trim(query)
	local country = SearchCountry()
	local showType = (filter == 'movie' or filter == 'series') and filter or nil
	local key = country .. '|' .. tostring(showType) .. '|' .. query:lower()
	local hit = Finder.cache[key]
	if (hit and (os.time() - hit.at) < SEARCH_CACHE_SECS) then
		callback(nil, hit.shows)
		return
	end
	local path = '/shows/search/title?title=' .. URLEncode(query) .. '&country=' .. country ..
		'&series_granularity=show&output_language=en'
	if (showType) then path = path .. '&show_type=' .. showType end
	SearchApiGet(path, function(err, data)
		if (err) then
			callback(err)
			return
		end
		if (type(data) ~= 'table') then
			callback('unexpected reply from search service')
			return
		end
		if (not Finder.cache[key]) then table.insert(Finder.cacheOrder, key) end
		Finder.cache[key] = { at = os.time(), shows = data }
		while (#Finder.cacheOrder > 30) do
			Finder.cache[table.remove(Finder.cacheOrder, 1)] = nil
		end
		RememberShows(data)
		callback(nil, data)
	end)
end

-- Which installed Shield app opens a service: known package first, then name.
function ResolveServiceApp(serviceId, serviceName)
	local apps = Bridge.appsByPackage or {}
	for _, pkg in ipairs(SERVICE_PACKAGES[serviceId] or {}) do
		if (apps[pkg]) then return pkg, apps[pkg].label end
	end
	local wanted = {}
	wanted[NormName(serviceName)] = true
	wanted[NormName(serviceId)] = true
	for _, a in ipairs(SERVICE_ALIASES[serviceId] or {}) do wanted[a] = true end
	wanted[''] = nil
	local best = nil
	for pkg, app in pairs(apps) do
		if (wanted[NormName(app.label)]) then
			if (not best or pkg < best) then best = pkg end  -- deterministic
		end
	end
	if (best) then return best, apps[best].label end
	return nil
end

function SearchTypeAllowed(t)
	local mode = Properties['Search Includes'] or 'Subscription and free'
	if (t == 'subscription' or t == 'free') then return true end
	if (t == 'addon') then return mode ~= 'Subscription and free' end
	if (t == 'rent' or t == 'buy') then return mode == 'Everything (incl. rent/buy)' end
	return false
end

-- One entry per service and offer type for our country, best quality kept,
-- split into ones an installed app can play and ones it cannot.
function ShowOptions(show)
	local raw = (type(show.streamingOptions) == 'table' and show.streamingOptions[SearchCountry()]) or {}
	local QRANK = { sd = 1, hd = 2, qhd = 3, uhd = 4 }
	local byKey, order = {}, {}
	for _, o in ipairs(raw) do
		local svc = o.service or {}
		if (svc.id and SearchTypeAllowed(o.type)) then
			local key = svc.id .. '|' .. tostring(o.type) .. '|' .. tostring(o.addon and o.addon.id or '')
			local cur = byKey[key]
			if (not cur) then
				table.insert(order, key)
				byKey[key] = o
			elseif ((QRANK[o.quality] or 0) > (QRANK[cur.quality] or 0)) then
				byKey[key] = o
			end
		end
	end
	local TRANK = { subscription = 1, free = 2, addon = 3, rent = 4, buy = 5 }
	local playable, missing = {}, {}
	for i, key in ipairs(order) do
		local o = byKey[key]
		local pkg, label = ResolveServiceApp(o.service.id, o.service.name)
		local e = { opt = o, package = pkg, appLabel = label, serviceId = o.service.id,
			serviceName = o.service.name or o.service.id, rank = (TRANK[o.type] or 9) * 100 + i }
		table.insert(pkg and playable or missing, e)
	end
	table.sort(playable, function(a, b) return a.rank < b.rank end)
	table.sort(missing, function(a, b) return a.rank < b.rank end)
	return playable, missing
end

function FindResumeRow(show, pkg)
	if (not pkg) then return nil end
	local want = NormName(show.title)
	if (want == '') then return nil end
	for _, item in ipairs(Bridge.items or {}) do
		if (item.package == pkg and NormName(item.title) == want) then return item end
	end
	return nil
end

function ShowPoster(show)
	local set = (type(show.imageSet) == 'table') and show.imageSet or {}
	local v = set.verticalPoster or {}
	if (v.w240 or v.w360) then return (v.w240 or v.w360), 240, 360 end
	local h = set.horizontalPoster or {}
	if (h.w360 or h.w480) then return (h.w360 or h.w480), 360, 203 end
	return nil
end

local function uniqueNames(entries, field, limit)
	local names, seen = {}, {}
	for _, e in ipairs(entries) do
		local n = e[field] or e.serviceName
		if (n and not seen[n]) then
			seen[n] = true
			table.insert(names, n)
		end
	end
	local s = table.concat(names, ', ', 1, math.min(#names, limit))
	if (#names > limit) then s = s .. ' +' .. (#names - limit) end
	return s
end

-- "2024 · Series · Netflix, Max"
function ShowSubtitle(show, playable, missing)
	local parts = {}
	local year = show.releaseYear or show.firstAirYear
	if (year) then table.insert(parts, tostring(year)) end
	table.insert(parts, show.showType == 'series' and 'Series' or 'Movie')
	if (#playable > 0) then
		table.insert(parts, uniqueNames(playable, 'appLabel', 3))
	elseif (#missing > 0) then
		table.insert(parts, 'On ' .. uniqueNames(missing, 'serviceName', 2) .. ' (app not on Shield)')
	else
		table.insert(parts, 'Not streaming in ' .. SearchCountry():upper())
	end
	return table.concat(parts, ' \194\183 ')
end

function ShowItemXml(show, playable, missing, actionable)
	local x = { '<item>' }
	table.insert(x, XMLTag('id', show.id))
	table.insert(x, XMLTag('title', show.title or '?'))
	table.insert(x, XMLTag('subtitle', ShowSubtitle(show, playable, missing)))
	local url, w, h = ShowPoster(show)
	if (url) then
		table.insert(x, '<image_list width="' .. w .. '" height="' .. h .. '">' .. XMLEncode(url) .. '</image_list>')
	end
	if (actionable) then
		table.insert(x, '<default_action>SearchPick</default_action>')
		if (#playable > 1) then table.insert(x, '<isLink>true</isLink>') end
	end
	table.insert(x, '</item>')
	return table.concat(x)
end

function BuildSearchResultsList(query, shows, notice)
	local x = { '<List>' }
	if (notice) then table.insert(x, HeaderXml(notice)) end
	local avail, unavail = {}, {}
	for _, show in ipairs(shows or {}) do
		local playable, missing = ShowOptions(show)
		table.insert((#playable > 0) and avail or unavail, { show, playable, missing })
	end
	for _, r in ipairs(avail) do table.insert(x, ShowItemXml(r[1], r[2], r[3], true)) end
	if (#unavail > 0 and (Properties['Show Titles Not On Shield'] or 'Yes') == 'Yes') then
		table.insert(x, HeaderXml("Not on your Shield's apps"))
		for _, r in ipairs(unavail) do table.insert(x, ShowItemXml(r[1], r[2], r[3], false)) end
	end
	if (not notice and #avail == 0 and #unavail == 0) then
		table.insert(x, '<item>' .. XMLTag('title', 'No matches for "' .. query .. '"') ..
			XMLTag('subtitle', 'Searched what streams in ' .. SearchCountry():upper()) .. '</item>')
	end
	table.insert(x, '<item>' .. XMLTag('id', 'tvsearch') .. XMLTag('title', 'Search "' .. query .. '" on the TV') ..
		XMLTag('subtitle', "Opens the Shield's own search") .. '<default_action>SearchOnTv</default_action></item>')
	table.insert(x, '</List>')
	return table.concat(x)
end

function OptionDescription(opt)
	local parts = {}
	local t = opt.type
	local price = (type(opt.price) == 'table' and opt.price.formatted) and (' ' .. opt.price.formatted) or ''
	if (t == 'subscription') then table.insert(parts, 'Included with subscription')
	elseif (t == 'free') then table.insert(parts, 'Free')
	elseif (t == 'addon') then table.insert(parts, ((type(opt.addon) == 'table' and opt.addon.name) or 'Add-on') .. ' add-on')
	elseif (t == 'rent') then table.insert(parts, 'Rent' .. price)
	elseif (t == 'buy') then table.insert(parts, 'Buy' .. price)
	end
	local Q = { uhd = '4K', qhd = 'QHD', hd = 'HD', sd = 'SD' }
	if (opt.quality and Q[opt.quality]) then table.insert(parts, Q[opt.quality]) end
	if (opt.expiresSoon == true) then table.insert(parts, 'Leaving soon') end
	return table.concat(parts, ' \194\183 ')
end

-- Netflix's TV app only jumps to a specific title when the link has source=30.
function TweakServiceUrl(serviceId, url)
	url = tostring(url or ''):gsub('#.*$', '')
	if (serviceId == 'netflix' and url:find('netflix%.com/title/') and not url:find('source=', 1, true)) then
		url = url .. (url:find('?', 1, true) and '&' or '?') .. 'source=30'
	end
	return url
end

-- Pins a web link to one app, so Android cannot hand it to a browser.
function UrlToAppIntent(url, pkg)
	local scheme, rest = tostring(url):match('^(%a[%w+.-]*)://(.+)$')
	if (not scheme or not pkg) then return nil end
	return 'intent://' .. rest .. '#Intent;scheme=' .. scheme .. ';package=' .. pkg ..
		';action=android.intent.action.VIEW;end'
end

-- Opens the title in the app; if the app refuses the link, opens the app.
function LaunchShowOption(show, e, roomId)
	local opt = e.opt
	local url = opt.link
	-- A movie's videoLink starts the film; for series the title page is safer
	-- than a link that might start episode one.
	if (show.showType == 'movie' and opt.videoLink and opt.videoLink ~= '') then url = opt.videoLink end
	url = TweakServiceUrl(e.serviceId, url)
	local display = { title = show.title or '', subtitle = e.appLabel or e.serviceName,
		app = e.appLabel or e.serviceName, art = ShowPoster(show), id = 'search:' .. tostring(show.id) }
	local intentUri = UrlToAppIntent(url, e.package)
	local target = intentUri and { intentUri = intentUri } or { package = e.package }
	LaunchOnShield(target, display, roomId, function(ok, err)
		if (ok or not intentUri) then return end
		print('Shield Bridge: ' .. tostring(e.appLabel or e.serviceName) .. ' would not open that title (' ..
			tostring(err) .. '); opening the app instead')
		LaunchOnShield({ package = e.package }, display, roomId)
	end)
end

-- Prefers an in-progress Continue Watching row, which resumes exactly.
function PlayShowOption(show, e, roomId, preferResume)
	if (preferResume) then
		local row = FindResumeRow(show, e.package)
		if (row) then
			LaunchItemById(row.id, roomId)
			return 'resume'
		end
	end
	LaunchShowOption(show, e, roomId)
	return 'title'
end

local SearchHistoryMax = 10

function PushSearchHistory(q)
	q = trim(q)
	if (q == '') then return end
	local hist = (type(PersistData.searchHistory) == 'table') and PersistData.searchHistory or {}
	local out = { q }
	for _, h in ipairs(hist) do
		if (h:lower() ~= q:lower() and #out < SearchHistoryMax) then table.insert(out, h) end
	end
	PersistData.searchHistory = out
end

-- Native search box, empty: recent searches as suggestions.
function RFP.GetSearchHistory(tParams, args, idBinding)
	local items = {}
	for _, h in ipairs((type(PersistData.searchHistory) == 'table') and PersistData.searchHistory or {}) do
		table.insert(items, '<item>' .. XMLTag('name', h) .. '</item>')
	end
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '<List>' .. table.concat(items) .. '</List>')
end

-- Results list. Reached from the native search box (query in args.search) or
-- from the Search tab's "Show results here" button (query typed there).
function RFP.SearchResults(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local query = trim(args.search)
	if (query == '') then query = trim(PersistData.searchQuery) end
	if (query == '') then
		DataReceived(idBinding, navId, seq, '<List></List>')
		return
	end
	Finder.lastQuery[tostring(navId)] = query
	PushSearchHistory(query)

	local function run(appsErr)
		FinderSearch(query, args.search_filter, function(err, shows)
			if (err) then
				local text = SearchErrorText(err)
				C4:UpdateProperty('Search Status', text)
				DataReceived(idBinding, navId, seq, BuildSearchResultsList(query, {}, text))
				return
			end
			C4:UpdateProperty('Search Status', string.format('OK: %d results for "%s" in %s', #shows, query, SearchCountry():upper()))
			local notice = appsErr and 'Shield Bridge offline: cannot tell which apps are installed' or nil
			DataReceived(idBinding, navId, seq, BuildSearchResultsList(query, shows, notice))
		end)
	end

	-- installed apps decide what is playable, so make sure we know them
	if (#(Bridge.apps or {}) == 0) then
		FetchApps(function(err) run(err) end)
	else
		run(nil)
	end
end

function RFP.SearchPick(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local id = tostring(args.id or '')
	local show = Finder.shows[id]
	if (not show) then
		DataReceivedError(idBinding, navId, seq, 'That result has expired; search again')
		return
	end
	local playable = ShowOptions(show)
	if (#playable == 0) then
		DataReceived(idBinding, navId, seq, '')
		return
	end
	Finder.lastShow[tostring(navId)] = id
	if (#playable == 1) then
		PlayShowOption(show, playable[1], tParams.ROOMID, true)
		DataReceived(idBinding, navId, seq, AfterLaunchScreen(tParams.ROOMID))
		return
	end
	DataReceived(idBinding, navId, seq, '<NextScreen>WhereToWatchScreen</NextScreen>')
end

function RFP.GetWhereToWatch(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local id = tostring(args.id or '')
	if (not Finder.shows[id]) then id = tostring(Finder.lastShow[tostring(navId)] or '') end
	local show = Finder.shows[id]
	if (not show) then
		DataReceivedError(idBinding, navId, seq, 'That result has expired; search again')
		return
	end
	local playable = ShowOptions(show)
	local x = { '<List>', HeaderXml(show.title or '') }
	local resumed = {}
	for i, e in ipairs(playable) do
		local row = FindResumeRow(show, e.package)
		if (row and not resumed[e.package]) then
			resumed[e.package] = true
			table.insert(x, '<item>' .. XMLTag('id', id .. '|r' .. i) ..
				XMLTag('title', 'Resume in ' .. tostring(e.appLabel or e.serviceName)) ..
				XMLTag('subtitle', ItemSubtitle(row)) .. '<default_action>SearchPlay</default_action></item>')
		end
	end
	for i, e in ipairs(playable) do
		table.insert(x, '<item>' .. XMLTag('id', id .. '|' .. i) ..
			XMLTag('title', tostring(e.appLabel or e.serviceName)) ..
			XMLTag('subtitle', OptionDescription(e.opt)) .. '<default_action>SearchPlay</default_action></item>')
	end
	table.insert(x, '</List>')
	DataReceived(idBinding, navId, seq, table.concat(x))
end

function RFP.SearchPlay(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local showId, tag = tostring(args.id or ''):match('^(.*)|(r?%d+)$')
	local show = showId and Finder.shows[showId]
	local resume = tag and tag:sub(1, 1) == 'r'
	local idx = tag and tonumber((tag:gsub('r', '')))
	local e = show and idx and ShowOptions(show)[idx]
	if (not e) then
		DataReceivedError(idBinding, navId, seq, 'That result has expired; search again')
		return
	end
	PlayShowOption(show, e, tParams.ROOMID, resume)
	DataReceived(idBinding, navId, seq, AfterLaunchScreen(tParams.ROOMID))
end

function RFP.SearchOnTv(tParams, args, idBinding)
	local q = Finder.lastQuery[tostring(tParams.NAVID)] or PersistData.searchQuery or ''
	if (trim(q) ~= '') then DoSearch(q, 'global', nil) end
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
end

-- Search tab button: show the typed query's results inside Control4.
function RFP.SearchHere(tParams, args, idBinding)
	if (trim(PersistData.searchQuery) == '') then
		DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
		return
	end
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>SearchResultsScreen</NextScreen>')
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

function EC.Search(tParams)
	local q = tParams.Query
	if (q and trim(q) ~= '') then
		DoSearch(q, tParams.Target, tParams.Room)
	end
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
	local dev = ResolveShieldDevice()
	if (dev) then
		local okName, name = pcall(function() return C4:GetDeviceDisplayName(dev) end)
		print('Remote keys relay to device ' .. dev .. ((okName and name) and (' (' .. tostring(name) .. ')') or ''))
	else
		print('Remote keys: no Shield Control Device chosen, so arrows and transport go nowhere')
	end
end

function EC.Test_Search(tParams)
	local q = trim(tParams.Query)
	if (q == '') then q = 'Severance' end
	FetchApps(function()
		FinderSearch(q, nil, function(err, shows)
			if (err) then
				local text = SearchErrorText(err)
				print('Shield Bridge search: ' .. text)
				C4:UpdateProperty('Search Status', text)
				return
			end
			local status = string.format('OK: %d results for "%s" in %s', #shows, q, SearchCountry():upper())
			print('Shield Bridge search ' .. status)
			C4:UpdateProperty('Search Status', status)
			for i = 1, math.min(#shows, 6) do
				local show = shows[i]
				local playable, missing = ShowOptions(show)
				print('  ' .. tostring(show.title) .. '  ->  ' .. ShowSubtitle(show, playable, missing))
			end
		end)
	end)
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

local function clearSearchCache()
	Finder.cache, Finder.cacheOrder = {}, {}
end
OPC.Search_API_Key = clearSearchCache
OPC.Search_API_Service = clearSearchCache

function OPC.Search_Country(value)
	clearSearchCache()
	local c = trim(value):lower():gsub('[^a-z]', '')
	if (trim(value) ~= '' and #c ~= 2) then
		C4:UpdateProperty('Search Status', 'Search Country should be a two-letter code like us, ca or gb; using us')
	end
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
	-- One-time safety reset: an existing instance keeps its stored property
	-- values on update, so force the no-power behaviour once. The installer can
	-- re-enable room power afterwards in Properties.
	if (not PersistData.powerSafeApplied) then
		C4:UpdateProperty('Select Room Source', 'Never')
		C4:UpdateProperty('Wake on Select', 'Off')
		PersistData.powerSafeApplied = true
		print('Shield Bridge: configured to send no room power commands (Select Room Source = Never, Wake on Select = Off). Change these in Properties to let the driver power the room.')
	end
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
