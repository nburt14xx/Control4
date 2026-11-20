--[[
Roku Bridge for Control4 - Media Service Proxy driver

A complete Roku driver: remote and transport keys, installed channels, a
search with posters (what streams where in one country), deep-link launch of
a title into the right channel, and a list of what was recently launched.

Talks to the Roku directly over its External Control Protocol (HTTP, port
8060); nothing is installed on the Roku. The Roku's "Control by mobile apps"
network setting must be Enabled or Permissive.

Lua 5.1 (Control4 DriverWorks).
--]]

DRIVER_VERSION = "0.1.1"

MSP_PROXY = 5001

-- Control4 serves the files inside a .c4z at controller://driver/<installed file
-- name without .c4z>/. driver.xml has to spell that name out, so the driver must
-- be installed as roku_bridge.c4z; under any other name every custom icon is a
-- "?". Paths built in Lua follow the real name.
DRIVER_FILE = 'roku_bridge'

Roku = Roku or {
	online = nil,       -- nil = unknown
	apps = {},          -- installed channels { id, name }, sorted by name
	appsById = {},
	appsAt = 0,
	activeApp = nil,    -- { id, name } from the last poll
	lastLaunched = nil,
	selected = false,
}

Timer = Timer or {}
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

function DriverFileName()
	local ok, name = pcall(function() return C4:GetDriverFileName() end)
	if (ok and type(name) == 'string' and name ~= '') then return name end
	return nil
end

function DriverFileBase()
	local name = DriverFileName()
	if (not name) then return DRIVER_FILE end
	return (name:gsub('%.[cC]4[zZiI]$', ''))
end

-- controller:// URL of a file inside this driver's package
function DriverAsset(path)
	local base = DriverFileBase():gsub('[^%w%-%._~%(%)]', function(c) return string.format('%%%02X', c:byte()) end)
	return 'controller://driver/' .. base .. '/' .. path
end

-- Shows the installed file name and warns when icons cannot load.
function CheckDriverFile()
	local name = DriverFileName()
	if (not name) then
		C4:UpdateProperty('Driver File', 'unknown')
		return true
	end
	if (DriverFileBase() == DRIVER_FILE) then
		C4:UpdateProperty('Driver File', name)
		return true
	end
	C4:UpdateProperty('Driver File', name .. ' (rename to ' .. DRIVER_FILE .. '.c4z)')
	print('Roku Bridge: installed as "' .. name .. '". Control4 finds the driver\'s icons by file name, so custom buttons show "?" and the device icon is generic. Install the file named exactly ' .. DRIVER_FILE .. '.c4z.')
	return false
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

function XMLDecode(s)
	if (s == nil) then return '' end
	s = tostring(s)
	s = s:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', "'")
	s = s:gsub('&#(%d+);', function(n) return string.char(tonumber(n) % 256) end)
	s = s:gsub('&amp;', '&')
	return s
end

function HeaderXml(text)
	return '<item>' .. XMLTag('title', text) .. '<isHeader>true</isHeader></item>'
end

-------------------------------------------------------------------------------
-- Roku ECP client (HTTP on port 8060, served by the Roku itself)
-------------------------------------------------------------------------------

LIMITED_HELP = 'Roku is refusing network control. On the Roku: Settings > System > Advanced system settings > ' ..
	'Control by mobile apps > Network access, set to Enabled (or Permissive)'

function RokuBase()
	local addr = trim(Properties['Roku Address'])
	if (addr == '') then return nil end
	addr = addr:gsub('^https?://', ''):gsub('/+$', '')
	if (not addr:find(':')) then addr = addr .. ':8060' end
	return 'http://' .. addr
end

function SetRokuOnline(online, reason)
	local was = Roku.online
	Roku.online = online
	if (was ~= online or reason ~= Roku.offlineReason) then
		Roku.offlineReason = reason
		C4:UpdateProperty('Roku Status', online and 'Online' or ('Offline' .. (reason and (': ' .. reason) or '')))
	end
	if (was ~= online) then
		C4:SetVariable('ROKU_ONLINE', online and 'true' or 'false')
		C4:FireEvent(online and 'Roku Online' or 'Roku Offline')
	end
end

-- callback(err, body, code). err is 'limited' when the Roku blocks the command.
function Ecp(method, path, callback)
	local base = RokuBase()
	if (not base) then
		if (callback) then callback('Roku Address property is empty') end
		return
	end
	local url = base .. path
	dbg('ECP ' .. method .. ' ' .. url)
	local function handle(ticketId, strData, responseCode, tHeaders, strError)
		strData = strData or ''
		local code = tonumber(responseCode) or 0
		if (strError and strError ~= '') then
			SetRokuOnline(false, tostring(strError))
			if (callback) then callback(tostring(strError), nil, code) end
			return
		end
		if (code == 401 or code == 403) then
			-- reachable, but "Control by mobile apps" is Limited or Disabled
			C4:UpdateProperty('Roku Status', LIMITED_HELP)
			Roku.offlineReason = 'limited'
			if (callback) then callback('limited', strData, code) end
			return
		end
		if (code < 200 or code >= 300) then
			if (callback) then callback('HTTP ' .. code, strData, code) end
			return
		end
		SetRokuOnline(true)
		if (callback) then callback(nil, strData, code) end
	end
	local ok, e = pcall(function()
		if (method == 'POST') then
			C4:urlPost(url, '', {}, false, handle)
		else
			C4:urlGet(url, {}, false, handle)
		end
	end)
	if (not ok and callback) then callback('request failed: ' .. tostring(e)) end
end

function KeyPress(key, mode)
	Ecp('POST', '/' .. (mode or 'keypress') .. '/' .. key, function(err)
		if (err == 'limited') then print('Roku Bridge: ' .. LIMITED_HELP) end
	end)
end

-------------------------------------------------------------------------------
-- Channels (installed apps)
-------------------------------------------------------------------------------

function ChannelIcon(id)
	local base = RokuBase()
	if (not base) then return '' end
	return base .. '/query/icon/' .. tostring(id)
end

function ParseApps(xml)
	local apps = {}
	for attrs, name in tostring(xml or ''):gmatch('<app%s([^>]*)>(.-)</app>') do
		local id = attrs:match('id="([^"]+)"')
		local atype = attrs:match('type="([^"]+)"') or 'appl'
		if (id and atype == 'appl') then
			table.insert(apps, { id = id, name = XMLDecode(name) })
		end
	end
	table.sort(apps, function(a, b) return a.name:lower() < b.name:lower() end)
	return apps
end

-- callback(err, apps)
function FetchChannels(callback)
	Ecp('GET', '/query/apps', function(err, body)
		if (err) then
			if (callback) then callback(err, Roku.apps) end
			return
		end
		local apps = ParseApps(body)
		Roku.apps, Roku.appsById = apps, {}
		for _, a in ipairs(apps) do Roku.appsById[a.id] = a end
		Roku.appsAt = os.time()
		if (callback) then callback(nil, apps) end
	end)
end

function BuildChannelsList(apps, notice)
	local x = { '<List>' }
	if (notice) then table.insert(x, HeaderXml(notice)) end
	for _, a in ipairs(apps or {}) do
		table.insert(x, '<item>' .. XMLTag('id', a.id) .. XMLTag('title', a.name) ..
			'<image_list width="290" height="218">' .. XMLEncode(ChannelIcon(a.id)) .. '</image_list>' ..
			'<default_action>LaunchChannel</default_action></item>')
	end
	if (#(apps or {}) == 0 and not notice) then
		table.insert(x, '<item>' .. XMLTag('title', 'No channels reported') .. '</item>')
	end
	table.insert(x, '</List>')
	return table.concat(x)
end

-------------------------------------------------------------------------------
-- Launching
-------------------------------------------------------------------------------

function RoomCurrentDevice(roomId)
	local ok, v = pcall(function() return C4:GetDeviceVariable(roomId, 1000) end)
	if (ok) then return tonumber(v) end
	return nil
end

-- For keypad or scene launches that should also turn the room on. Launches
-- from Navigator need no room command: the user is already on this source.
function SelectInRoom(roomId)
	roomId = tonumber(roomId)
	if (not roomId or roomId == 0) then return end
	if ((Properties['Select Room Source'] or 'Never') ~= 'Select Roku Bridge') then return end
	local targetId = C4:GetProxyDevices()
	if (RoomCurrentDevice(roomId) == targetId) then return end
	C4:SendToDevice(roomId, 'SELECT_VIDEO_DEVICE', { deviceid = targetId })
end

function SetNowPlaying(display)
	Roku.lastLaunched = display
	C4:SetVariable('LAST_LAUNCHED_TITLE', display.title or '')
	C4:SetVariable('LAST_LAUNCHED_APP', display.app or '')
	UpdateMediaInfo()
	UpdateQueue()
	UpdateDashboard()
	C4:FireEvent('Item Launched')
end

-- contentId nil launches the channel's home screen.
function LaunchChannel(channelId, contentId, mediaType, display, roomId)
	SelectInRoom(roomId)
	local path = '/launch/' .. tostring(channelId)
	if (contentId and contentId ~= '') then
		path = path .. '?contentId=' .. URLEncode(contentId) .. '&mediaType=' .. URLEncode(mediaType or 'movie')
		-- always shown: this is what to quote when a title opens the wrong place
		print(string.format('Roku Bridge: launch %s (channel %s) contentId=%s mediaType=%s',
			tostring(display and display.app or ''), tostring(channelId), contentId, tostring(mediaType)))
	end
	Ecp('POST', path, function(err)
		if (err) then
			local text = (err == 'limited') and LIMITED_HELP or ('Launch failed: ' .. tostring(err))
			print('Roku Bridge: ' .. text)
			C4:UpdateProperty('Roku Status', text)
		end
	end)
	if (display) then SetNowPlaying(display) end
end

function AfterLaunchScreen()
	if ((Properties['After Launch'] or 'Go to Now Playing') == 'Go to Now Playing') then
		return '<NextScreen>#nowplaying</NextScreen>'
	end
	return ''
end

-------------------------------------------------------------------------------
-- Recently launched (kept by the driver; Roku exposes no watch history)
-------------------------------------------------------------------------------

function RecentList()
	if (type(PersistData.recent) ~= 'table') then PersistData.recent = {} end
	return PersistData.recent
end

function RecentKey(rec)
	return tostring(rec.channelId) .. '|' .. tostring(rec.contentId)
end

function PushRecent(rec)
	local max = tonumber(Properties['Recent List Size']) or 20
	local key = RecentKey(rec)
	local out = { rec }
	for _, r in ipairs(RecentList()) do
		if (RecentKey(r) ~= key and #out < max) then table.insert(out, r) end
	end
	PersistData.recent = out
end

function FindRecent(key)
	for _, r in ipairs(RecentList()) do
		if (RecentKey(r) == key) then return r end
	end
	return nil
end

function RecentItemXml(r)
	local x = { '<item>', XMLTag('id', RecentKey(r)), XMLTag('title', r.title or '?'), XMLTag('subtitle', r.subtitle or '') }
	if (r.poster and r.poster ~= '') then
		table.insert(x, '<image_list width="240" height="360">' .. XMLEncode(r.poster) .. '</image_list>')
	end
	table.insert(x, '<default_action>LaunchRecent</default_action><actions_list>LaunchRecent RemoveRecent</actions_list></item>')
	return table.concat(x)
end

function BuildRecentList()
	local x = { '<List>' }
	local list = RecentList()
	for _, r in ipairs(list) do table.insert(x, RecentItemXml(r)) end
	if (#list == 0) then
		table.insert(x, '<item>' .. XMLTag('title', 'Nothing here yet') ..
			XMLTag('subtitle', 'Titles you start from Search appear here so you can jump back in') .. '</item>')
	end
	table.insert(x, '</List>')
	return table.concat(x)
end

function LaunchRecentRecord(r, roomId)
	LaunchChannel(r.channelId, r.contentId, r.mediaType,
		{ title = r.title, subtitle = r.subtitle, app = r.channelName, art = r.poster, key = RecentKey(r) }, roomId)
	PushRecent(r)  -- move to the top
end

-------------------------------------------------------------------------------
-- Remote keys
-------------------------------------------------------------------------------

KEYMAP = {
	UP = 'Up', DOWN = 'Down', LEFT = 'Left', RIGHT = 'Right', ENTER = 'Select',
	CANCEL = 'Back', RECALL = 'Back', MENU = 'Home', HOME = 'Home', INFO = 'Info', GUIDE = 'Info', STAR = 'Info',
	SCAN_REV = 'Rev', SCAN_FWD = 'Fwd', SKIP_REV = 'InstantReplay', SKIP_FWD = 'Fwd',
	PAGE_UP = 'Rev', PAGE_DOWN = 'Fwd', POUND = 'Backspace', PLAYPAUSE = 'Play',
	CH_UP = 'ChannelUp', CH_DOWN = 'ChannelDown',
	NUMBER_0 = 'Lit_0', NUMBER_1 = 'Lit_1', NUMBER_2 = 'Lit_2', NUMBER_3 = 'Lit_3', NUMBER_4 = 'Lit_4',
	NUMBER_5 = 'Lit_5', NUMBER_6 = 'Lit_6', NUMBER_7 = 'Lit_7', NUMBER_8 = 'Lit_8', NUMBER_9 = 'Lit_9',
}

-- Roku has one Play key that toggles. Control4 sends PLAY and PAUSE as
-- separate commands, so check what the player is doing first and only toggle
-- when that changes something. If the channel does not report, just toggle.
function SmartPlayPause(want)
	Ecp('GET', '/query/media-player', function(err, body)
		local state = (not err) and tostring(body):match('<player[^>]-state="([^"]+)"') or nil
		if (want == 'play' and state == 'play') then return end
		if (want == 'pause' and state == 'pause') then return end
		KeyPress('Play')
	end)
end

-- Returns true when the command was a remote key.
function HandleKeyCommand(strCommand)
	if (strCommand == 'PLAY') then SmartPlayPause('play') return true end
	if (strCommand == 'PAUSE' or strCommand == 'STOP') then SmartPlayPause('pause') return true end
	local key = KEYMAP[strCommand]
	if (key) then KeyPress(key) return true end
	local prefix, base = strCommand:match('^(%u+)_(.+)$')
	key = base and KEYMAP[base]
	if (not key) then return false end
	if (prefix == 'START') then KeyPress(key, 'keydown') return true end
	if (prefix == 'STOP' or prefix == 'END') then KeyPress(key, 'keyup') return true end
	if (prefix == 'PULSE') then KeyPress(key) return true end
	return false
end

-- Types text into whatever field is focused on the Roku, one key at a time.
function SendText(text, i)
	i = i or 1
	if (i > #text) then return end
	Ecp('POST', '/keypress/Lit_' .. URLEncode(text:sub(i, i)), function(err)
		if (not err) then SendText(text, i + 1) end
	end)
end

REMOTE_KEYS = {
	{ 'UP', 'Up', 'nav_up' }, { 'DOWN', 'Down', 'nav_down' }, { 'LEFT', 'Left', 'nav_left' },
	{ 'RIGHT', 'Right', 'nav_right' }, { 'ENTER', 'OK / Select', 'nav_ok' }, { 'CANCEL', 'Back', 'nav_back' },
	{ 'HOME', 'Home', 'nav_home' }, { 'PLAYPAUSE', 'Play / Pause', 'nav_playpause' },
	{ 'SCAN_REV', 'Rewind', 'nav_rew' }, { 'SCAN_FWD', 'Fast Forward', 'nav_ff' },
	{ 'SKIP_REV', 'Instant Replay', 'nav_back' }, { 'INFO', 'Options (*)', 'nav_ok' },
}

-------------------------------------------------------------------------------
-- Search (Streaming Availability API by Movie of the Night)
--
-- Titles come from a public availability database scoped to one country.
-- Each result is matched to the channels installed on the Roku; tapping it
-- deep-links into that channel. Channels that are not installed can be opened
-- on their Roku install page.
-------------------------------------------------------------------------------

SEARCH_CACHE_SECS = 600

-- Roku channel ids for the API's service ids. Anything missing is matched by
-- name against the channels the Roku reports.
SERVICE_CHANNELS = {
	netflix = { '12' }, prime = { '13' }, hulu = { '2285' }, disney = { '291097' },
	hbo = { '61322' }, apple = { '551012' }, paramount = { '31440' }, peacock = { '593099' },
	crunchyroll = { '2595' }, tubi = { '41468' }, plutotv = { '74519' }, starz = { '65067' },
	vudu = { '13842' },
}

SERVICE_ALIASES = {
	hbo = { 'max', 'hbomax' },
	apple = { 'appletv' },
	prime = { 'primevideo', 'amazonprimevideo' },
	plutotv = { 'pluto', 'plutotv', 'plutotvitsfreetv' },
	vudu = { 'vudu', 'fandangoathome' },
	tubi = { 'tubi', 'tubifreemoviestv', 'tubitv' },
}

Finder = Finder or { cache = {}, cacheOrder = {}, shows = {}, showCount = 0, lastShow = {} }

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

function SearchTypeAllowed(t)
	local mode = Properties['Search Includes'] or 'Subscription and free'
	if (t == 'subscription' or t == 'free') then return true end
	if (t == 'addon') then return mode ~= 'Subscription and free' end
	if (t == 'rent' or t == 'buy') then return mode == 'Everything (incl. rent/buy)' end
	return false
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

-- Returns channelId, name, installed. A known but uninstalled channel can
-- still be opened on its install page.
function ResolveServiceChannel(serviceId, serviceName)
	local known = SERVICE_CHANNELS[serviceId] or {}
	for _, id in ipairs(known) do
		if (Roku.appsById[id]) then return id, Roku.appsById[id].name, true end
	end
	local wanted = {}
	wanted[NormName(serviceName)] = true
	wanted[NormName(serviceId)] = true
	for _, a in ipairs(SERVICE_ALIASES[serviceId] or {}) do wanted[a] = true end
	wanted[''] = nil
	for _, app in ipairs(Roku.apps) do
		if (wanted[NormName(app.name)]) then return app.id, app.name, true end
	end
	if (known[1]) then return known[1], serviceName or serviceId, false end
	return nil, serviceName or serviceId, false
end

-- One entry per service and offer type for our country, best quality kept:
-- playable (channel installed), installable (channel known), other.
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
	local playable, installable, other = {}, {}, {}
	for i, key in ipairs(order) do
		local o = byKey[key]
		local chId, chName, installed = ResolveServiceChannel(o.service.id, o.service.name)
		local e = { opt = o, channelId = chId, appLabel = chName, serviceId = o.service.id,
			serviceName = o.service.name or o.service.id, rank = (TRANK[o.type] or 9) * 100 + i }
		table.insert(installed and playable or (chId and installable or other), e)
	end
	local function byRank(a, b) return a.rank < b.rank end
	table.sort(playable, byRank)
	table.sort(installable, byRank)
	table.sort(other, byRank)
	return playable, installable, other
end

-- "2024 · Series · Netflix, Hulu"
function ShowSubtitle(show, playable, installable, other)
	local parts = {}
	local year = show.releaseYear or show.firstAirYear
	if (year) then table.insert(parts, tostring(year)) end
	table.insert(parts, show.showType == 'series' and 'Series' or 'Movie')
	if (#playable > 0) then
		table.insert(parts, uniqueNames(playable, 'appLabel', 3))
	elseif (#installable > 0) then
		table.insert(parts, 'On ' .. uniqueNames(installable, 'serviceName', 2) .. ' (not installed)')
	elseif (#other > 0) then
		table.insert(parts, 'On ' .. uniqueNames(other, 'serviceName', 2))
	else
		table.insert(parts, 'Not streaming in ' .. SearchCountry():upper())
	end
	return table.concat(parts, ' \194\183 ')
end

function ShowItemXml(show, playable, installable, other)
	local x = { '<item>' }
	table.insert(x, XMLTag('id', show.id))
	table.insert(x, XMLTag('title', show.title or '?'))
	table.insert(x, XMLTag('subtitle', ShowSubtitle(show, playable, installable, other)))
	local url, w, h = ShowPoster(show)
	if (url) then
		table.insert(x, '<image_list width="' .. w .. '" height="' .. h .. '">' .. XMLEncode(url) .. '</image_list>')
	end
	if (#playable + #installable > 0) then
		table.insert(x, '<default_action>SearchPick</default_action>')
		if (#playable ~= 1) then table.insert(x, '<isLink>true</isLink>') end
	end
	table.insert(x, '</item>')
	return table.concat(x)
end

function BuildSearchResultsList(query, shows, notice)
	local x = { '<List>' }
	if (notice) then table.insert(x, HeaderXml(notice)) end
	local avail, install, rest = {}, {}, {}
	for _, show in ipairs(shows or {}) do
		local p, i, o = ShowOptions(show)
		local bucket = (#p > 0) and avail or ((#i > 0) and install or rest)
		table.insert(bucket, { show, p, i, o })
	end
	for _, r in ipairs(avail) do table.insert(x, ShowItemXml(r[1], r[2], r[3], r[4])) end
	local showOthers = (Properties['Show Titles Not On Roku'] or 'Yes') == 'Yes'
	if (#install > 0 and showOthers) then
		table.insert(x, HeaderXml('On channels you can add'))
		for _, r in ipairs(install) do table.insert(x, ShowItemXml(r[1], r[2], r[3], r[4])) end
	end
	if (#rest > 0 and showOthers) then
		table.insert(x, HeaderXml('Not available on this Roku'))
		for _, r in ipairs(rest) do table.insert(x, ShowItemXml(r[1], r[2], r[3], r[4])) end
	end
	if (not notice and #avail + #install + #rest == 0) then
		table.insert(x, '<item>' .. XMLTag('title', 'No matches for "' .. query .. '"') ..
			XMLTag('subtitle', 'Searched what streams in ' .. SearchCountry():upper()) .. '</item>')
	end
	table.insert(x, '</List>')
	return table.concat(x)
end

-- How each service's Roku channel names a title. The database gives a web
-- link; the id the channel wants is normally inside it. First match wins. A
-- wrong id is harmless: Roku opens the channel's home screen.
local UUID = '(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)'
CONTENT_ID_RULES = {
	netflix = { 'netflix%.com/title/(%d+)', 'netflix%.com/watch/(%d+)' },
	hulu = { UUID },
	disney = { 'entity%-([%w%-]+)', UUID },
	hbo = { '/show/([%w%-]+)', '/movie/([%w%-]+)', '/video/watch/([%w%-]+)', UUID },
	prime = { '/detail/([%w%.%-]+)', '/dp/(%w+)', 'gti=([%w%.%-]+)' },
	apple = { '(umc%.[%w%.]+)' },
	crunchyroll = { '/series/(%w+)', '/watch/(%w+)' },
	tubi = { '/movies/(%d+)', '/series/(%d+)', '/tv%-shows/(%d+)', '/video/(%d+)' },
}

function RokuContentId(serviceId, url)
	url = tostring(url or ''):gsub('[?#].*$', ''):gsub('/+$', '')
	for _, pat in ipairs(CONTENT_ID_RULES[serviceId] or {}) do
		local id = url:match(pat)
		if (id) then return id end
	end
	-- fallback: the last path segment
	return url:match('([^/]+)$')
end

function LaunchShowOption(show, e, roomId)
	local opt = e.opt
	local mediaType = (show.showType == 'series') and 'series' or 'movie'
	local contentId = RokuContentId(e.serviceId, opt.link)
	local poster = ShowPoster(show)
	local rec = { title = show.title or '', subtitle = e.appLabel, poster = poster or '', channelId = e.channelId,
		channelName = e.appLabel, contentId = contentId or '', mediaType = mediaType, serviceId = e.serviceId }
	LaunchChannel(e.channelId, contentId, mediaType,
		{ title = rec.title, subtitle = rec.subtitle, app = rec.channelName, art = poster, key = RecentKey(rec) }, roomId)
	PushRecent(rec)
end

function InstallChannel(e)
	print('Roku Bridge: opening the install page for ' .. tostring(e.serviceName) .. ' (channel ' .. tostring(e.channelId) .. ')')
	Ecp('POST', '/install/' .. tostring(e.channelId), function(err)
		if (err) then print('Roku Bridge: install request failed: ' .. ((err == 'limited') and LIMITED_HELP or tostring(err))) end
	end)
	Roku.appsAt = 0  -- re-read the channel list next time
end

-------------------------------------------------------------------------------
-- Now Playing
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
	local last = Roku.lastLaunched
	local active = Roku.activeApp
	-- show the launched title only while its channel is still the active one
	if (last and active and active.id and last.channelId and tostring(active.id) ~= tostring(last.channelId)) then
		last = nil
	end
	local args = {
		TITLE = (last and last.title) or (active and active.name) or 'Roku',
		ALBUM = (last and last.subtitle) or '',
		ARTIST = (last and last.app) or (active and active.name) or 'Roku',
		GENRE = '',
	}
	local art = (last and last.art and last.art ~= '') and last.art or (active and active.id and ChannelIcon(active.id)) or nil
	if (art and art ~= '') then args.IMAGEURL = C4:Base64Encode(art) end
	C4:SendToProxy(MSP_PROXY, 'UPDATE_MEDIA_INFO', args, 'COMMAND', true)
end

function UpdateDashboard(navId, roomId)
	SendEvent(MSP_PROXY, navId, roomId, 'DashboardChanged', '<Items>ScanRev Play Pause ScanFwd Replay</Items>')
end

function UpdateQueue(navId, roomId)
	local x = {}
	local last = Roku.lastLaunched
	if (last) then
		table.insert(x, HeaderXml('Now Playing'))
		table.insert(x, '<item>' .. XMLTag('title', last.title) .. XMLTag('subtitle', last.subtitle or '') ..
			((last.art and last.art ~= '') and ('<image_list width="240" height="360">' .. XMLEncode(last.art) .. '</image_list>') or '') ..
			'</item>')
	end
	local shown = 0
	for _, r in ipairs(RecentList()) do
		if (not last or RecentKey(r) ~= last.key) then
			if (shown == 0) then table.insert(x, HeaderXml('Recently launched')) end
			table.insert(x, RecentItemXml(r))
			shown = shown + 1
			if (shown >= 8) then break end
		end
	end
	SendEvent(MSP_PROXY, navId, roomId, 'QueueChanged',
		'<List>' .. table.concat(x) .. '</List><NowPlayingIndex>' .. (last and 1 or 0) .. '</NowPlayingIndex>')
end

local function fmtClock(sec)
	sec = math.floor(sec)
	local h, m, s = math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60
	if (h > 0) then return string.format('%d:%02d:%02d', h, m, s) end
	return string.format('%d:%02d', m, s)
end

-- Reads what the Roku is doing and refreshes the Now Playing bar.
function PollNowPlaying()
	Ecp('GET', '/query/active-app', function(err, body)
		if (err) then return end
		local attrs, name = tostring(body):match('<app([^>]*)>(.-)</app>')
		local id = attrs and attrs:match('id="([^"]+)"') or nil
		local prev = Roku.activeApp and Roku.activeApp.name
		Roku.activeApp = { id = id, name = XMLDecode(name or 'Roku') }
		C4:SetVariable('ACTIVE_APP', Roku.activeApp.name)
		if (prev ~= Roku.activeApp.name) then UpdateMediaInfo() end
	end)
	Ecp('GET', '/query/media-player', function(err, body)
		if (err) then return end
		body = tostring(body)
		local pos = tonumber(body:match('<position>(%d+)')) or 0
		local dur = tonumber(body:match('<duration>(%d+)')) or 0
		if (dur > 0) then
			SendEvent(MSP_PROXY, nil, nil, 'ProgressChanged', '<length>' .. math.floor(dur / 1000) .. '</length><offset>' ..
				math.floor(pos / 1000) .. '</offset><label>' .. fmtClock(pos / 1000) .. ' / ' .. fmtClock(dur / 1000) .. '</label>')
		end
	end)
end

function StartNowPlayingPoll()
	KillTimer('np')
	PollNowPlaying()
	local secs = tonumber(Properties['Now Playing Refresh (s)']) or 10
	if (secs <= 0) then return end
	Timer.np = C4:SetTimer(secs * 1000, function() PollNowPlaying() end, true)
end

-------------------------------------------------------------------------------
-- Navigator handlers. Each receives (tParams, args, idBinding).
-------------------------------------------------------------------------------

RFP = {}

function RFP.GetChannels(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	FetchChannels(function(err, apps)
		if (err and #(apps or {}) == 0) then
			DataReceivedError(idBinding, navId, seq, (err == 'limited') and LIMITED_HELP or ('Roku unreachable: ' .. tostring(err)))
			return
		end
		DataReceived(idBinding, navId, seq, BuildChannelsList(apps, err and 'Roku offline, showing last known channels' or nil))
	end)
end

function RFP.LaunchChannel(tParams, args, idBinding)
	local id = tostring(args.id or '')
	if (id == '') then
		DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, 'No channel selected')
		return
	end
	local app = Roku.appsById[id]
	local name = app and app.name or ('Channel ' .. id)
	LaunchChannel(id, nil, nil, { title = name, app = name, art = ChannelIcon(id), channelId = id }, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, AfterLaunchScreen())
end

function RFP.GetRecent(tParams, args, idBinding)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, BuildRecentList())
end

function RFP.LaunchRecent(tParams, args, idBinding)
	local r = FindRecent(tostring(args.id or ''))
	if (not r) then
		DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, 'That entry is no longer in the list')
		return
	end
	LaunchRecentRecord(r, tParams.ROOMID)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, AfterLaunchScreen())
end

function RFP.RemoveRecent(tParams, args, idBinding)
	local key, out = tostring(args.id or ''), {}
	for _, r in ipairs(RecentList()) do
		if (RecentKey(r) ~= key) then table.insert(out, r) end
	end
	PersistData.recent = out
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>RecentScreen</NextScreen>')
end

function RFP.GetRemote(tParams, args, idBinding)
	local x = { '<List>' }
	for _, k in ipairs(REMOTE_KEYS) do
		local icon = DriverAsset('icons/' .. k[3] .. '/' .. k[3] .. '_140.png')
		table.insert(x, '<item>' .. XMLTag('id', k[1]) .. XMLTag('title', k[2]) ..
			'<image_list width="140" height="140">' .. icon .. '</image_list>' ..
			'<default_action>RemoteKey</default_action></item>')
	end
	table.insert(x, '</List>')
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, table.concat(x))
end

function RFP.RemoteKey(tParams, args, idBinding)
	local key = tostring(args.id or '')
	for _, k in ipairs(REMOTE_KEYS) do
		if (k[1] == key) then HandleKeyCommand(key) break end
	end
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')  -- stay on the remote
end

function RFP.GetSearchHistory(tParams, args, idBinding)
	local items = {}
	for _, h in ipairs((type(PersistData.searchHistory) == 'table') and PersistData.searchHistory or {}) do
		table.insert(items, '<item>' .. XMLTag('name', h) .. '</item>')
	end
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '<List>' .. table.concat(items) .. '</List>')
end

function RFP.SearchResults(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local query = trim(args.search)
	if (query == '') then query = trim(PersistData.searchQuery) end
	if (query == '') then
		DataReceived(idBinding, navId, seq, '<List></List>')
		return
	end
	PushSearchHistory(query)

	local function run(chErr)
		FinderSearch(query, args.search_filter, function(err, shows)
			if (err) then
				local text = SearchErrorText(err)
				C4:UpdateProperty('Search Status', text)
				DataReceived(idBinding, navId, seq, BuildSearchResultsList(query, {}, text))
				return
			end
			C4:UpdateProperty('Search Status', string.format('OK: %d results for "%s" in %s', #shows, query, SearchCountry():upper()))
			local notice = chErr and 'Roku offline: cannot tell which channels are installed' or nil
			DataReceived(idBinding, navId, seq, BuildSearchResultsList(query, shows, notice))
		end)
	end

	-- installed channels decide what is playable; refresh them now and then
	if (#Roku.apps == 0 or (os.time() - (Roku.appsAt or 0)) > 300) then
		FetchChannels(function(err) run(err) end)
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
	local playable, installable = ShowOptions(show)
	if (#playable + #installable == 0) then
		DataReceived(idBinding, navId, seq, '')
		return
	end
	Finder.lastShow[tostring(navId)] = id
	if (#playable == 1) then
		LaunchShowOption(show, playable[1], tParams.ROOMID)
		DataReceived(idBinding, navId, seq, AfterLaunchScreen())
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
	local playable, installable = ShowOptions(show)
	local x = { '<List>', HeaderXml(show.title or '') }
	for i, e in ipairs(playable) do
		table.insert(x, '<item>' .. XMLTag('id', id .. '|' .. i) .. XMLTag('title', tostring(e.appLabel)) ..
			XMLTag('subtitle', OptionDescription(e.opt)) ..
			'<image_list width="290" height="218">' .. XMLEncode(ChannelIcon(e.channelId)) .. '</image_list>' ..
			'<default_action>SearchPlay</default_action></item>')
	end
	if (#installable > 0) then
		table.insert(x, HeaderXml('Not installed'))
		for i, e in ipairs(installable) do
			table.insert(x, '<item>' .. XMLTag('id', id .. '|i' .. i) ..
				XMLTag('title', 'Add ' .. tostring(e.serviceName) .. ' to the Roku') ..
				XMLTag('subtitle', OptionDescription(e.opt)) .. '<default_action>SearchPlay</default_action></item>')
		end
	end
	table.insert(x, '</List>')
	DataReceived(idBinding, navId, seq, table.concat(x))
end

function RFP.SearchPlay(tParams, args, idBinding)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local showId, tag = tostring(args.id or ''):match('^(.*)|(i?%d+)$')
	local show = showId and Finder.shows[showId]
	local install = tag and tag:sub(1, 1) == 'i'
	local idx = tag and tonumber((tag:gsub('i', '')))
	local e = nil
	if (show and idx) then
		local playable, installable = ShowOptions(show)
		e = install and installable[idx] or playable[idx]
	end
	if (not e) then
		DataReceivedError(idBinding, navId, seq, 'That result has expired; search again')
		return
	end
	if (install) then
		InstallChannel(e)
		DataReceived(idBinding, navId, seq, '')
		return
	end
	LaunchShowOption(show, e, tParams.ROOMID)
	DataReceived(idBinding, navId, seq, AfterLaunchScreen())
end

-- Search tab (fallback for navigators that do not show the magnifier)
function RFP.GetSearch(tParams, args, idBinding)
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ,
		'<Settings><SearchQuery>' .. XMLEncode(PersistData.searchQuery or '') .. '</SearchQuery></Settings>')
end

function RFP.SettingChanged(tParams, args, idBinding)
	if ((args.PropertyName or args.propertyName) == 'SearchQuery') then
		PersistData.searchQuery = args.Value or args.value or ''
	end
end

function RFP.SearchHere(tParams, args, idBinding)
	if (trim(PersistData.searchQuery) == '') then
		DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '')
		return
	end
	DataReceived(idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>SearchResultsScreen</NextScreen>')
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
	Roku.selected = true
	if ((Properties['Power Commands'] or 'Off') ~= 'Off') then KeyPress('PowerOn') end
	UpdateMediaInfo()
	UpdateDashboard()
	StartNowPlayingPoll()
end
RFP.ON = RFP.DEVICE_SELECTED

function RFP.DEVICE_DESELECTED(tParams, args, idBinding)
	Roku.selected = false
	KillTimer('np')
	local mode = Properties['Power Commands'] or 'Off'
	if (mode == 'Roku TV: power on and off') then
		KeyPress('PowerOff')
	elseif (mode == 'Go Home when room turns off') then
		KeyPress('Home')
	end
end
RFP.OFF = RFP.DEVICE_DESELECTED

function RFP.SET_INPUT() end
function RFP.CONNECT_OUTPUT() end
function RFP.DISCONNECT_OUTPUT() end
function RFP.INPUT_OUTPUT_CHANGED() end
function RFP.DESTROY_NAVIGATOR() end
function RFP.DESTROY_NAV() end

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
			print('Roku Bridge: error in ' .. strCommand .. ': ' .. tostring(err))
			if (tParams.NAVID and tParams.SEQ) then
				DataReceivedError(idBinding, tParams.NAVID, tParams.SEQ, tostring(err))
			end
		end
		return
	end

	local handled = HandleKeyCommand(strCommand)
	if (not handled) then dbg('unhandled proxy command ' .. strCommand) end
	-- on-screen buttons wait for a reply even though keys return nothing
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
	local fn = EC[(strCommand:gsub('%s+', '_'))]
	if (not fn) then
		dbg('unhandled command ' .. strCommand)
		return
	end
	local ok, err = pcall(fn, tParams)
	if (not ok) then print('Roku Bridge: command ' .. strCommand .. ' failed: ' .. tostring(err)) end
end

function EC.Launch_Channel(tParams)
	local id = tostring(tParams.Channel or '')
	if (id == '') then return end
	local app = Roku.appsById[id]
	local name = app and app.name or ('Channel ' .. id)
	LaunchChannel(id, nil, nil, { title = name, app = name, art = ChannelIcon(id), channelId = id }, tParams.Room)
end

function EC.Launch_Deep_Link(tParams)
	local id = trim(tParams['Channel ID'])
	if (id == '') then return end
	local mt = trim(tParams['Media Type'])
	LaunchChannel(id, trim(tParams['Content ID']), (mt ~= '') and mt or 'movie', { title = 'Channel ' .. id, app = 'Channel ' .. id, channelId = id }, tParams.Room)
end

function EC.Resume_Latest(tParams)
	local r = RecentList()[1]
	if (not r) then
		print('Roku Bridge: nothing in the recent list yet')
		return
	end
	LaunchRecentRecord(r, tParams.Room)
end

function EC.Send_Key(tParams)
	local key = trim(tParams.Key)
	if (key ~= '') then KeyPress(key) end
end

function EC.Send_Text(tParams)
	SendText(tostring(tParams.Text or ''))
end

function EC.Clear_Recent(tParams)
	PersistData.recent = {}
end

function EC.Refresh(tParams)
	FetchChannels(nil)
end

function EC.Test_Connection(tParams)
	if (CheckDriverFile()) then
		print('Roku Bridge: driver file ' .. (DriverFileName() or 'unknown') .. ' (icons OK)')
	end
	Ecp('GET', '/query/device-info', function(err, body)
		if (err == 'limited') then
			print('Roku Bridge: ' .. LIMITED_HELP)
			return
		elseif (err) then
			print('Roku Bridge: Roku NOT reachable: ' .. tostring(err))
			return
		end
		body = tostring(body)
		local function field(n) return XMLDecode(body:match('<' .. n .. '>(.-)</' .. n .. '>') or '?') end
		print(string.format('Roku Bridge: %s (%s), Roku OS %s, network control: %s',
			field('friendly%-device%-name'), field('model%-name'), field('software%-version'), field('ecp%-setting%-mode')))
		-- device-info is readable even when control is blocked, so try a real command
		FetchChannels(function(e2, apps)
			if (e2 == 'limited') then
				print('Roku Bridge: ' .. LIMITED_HELP)
			elseif (e2) then
				print('Roku Bridge: could not read channels: ' .. tostring(e2))
			else
				print('Roku Bridge: ' .. #apps .. ' channels installed; control is working')
			end
		end)
	end)
end

function EC.Test_Search(tParams)
	local q = trim(tParams.Query)
	if (q == '') then q = 'Severance' end
	FetchChannels(function()
		FinderSearch(q, nil, function(err, shows)
			if (err) then
				local text = SearchErrorText(err)
				print('Roku Bridge search: ' .. text)
				C4:UpdateProperty('Search Status', text)
				return
			end
			local status = string.format('OK: %d results for "%s" in %s', #shows, q, SearchCountry():upper())
			print('Roku Bridge search ' .. status)
			C4:UpdateProperty('Search Status', status)
			for i = 1, math.min(#shows, 6) do
				local show = shows[i]
				local p, ins, o = ShowOptions(show)
				local line = '  ' .. tostring(show.title) .. '  ->  ' .. ShowSubtitle(show, p, ins, o)
				if (p[1]) then
					line = line .. '   [channel ' .. tostring(p[1].channelId) .. ' contentId=' ..
						tostring(RokuContentId(p[1].serviceId, p[1].opt.link)) .. ']'
				end
				print(line)
			end
		end)
	end)
end

function ChannelSelect(currentValue)
	local out = {}
	for _, a in ipairs(Roku.apps) do table.insert(out, { text = a.name, value = a.id }) end
	if (#out == 0) then table.insert(out, { text = '(no channels yet - run Refresh in Actions)', value = '' }) end
	return out
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

OPC = {}

function OPC.Debug_Mode(value) DEBUGPRINT = (value == 'On') end

function OPC.Roku_Address(value)
	Roku.online = nil
	if (trim(value) ~= '') then FetchChannels(nil) end
end

local function clearSearchCache()
	Finder.cache, Finder.cacheOrder = {}, {}
end
OPC.Search_API_Key = clearSearchCache
OPC.Search_API_Service = clearSearchCache
OPC.Search_Country = clearSearchCache

function OnPropertyChanged(strProperty)
	local value = Properties[strProperty]
	if (value == nil) then value = '' end
	local fn = OPC[(strProperty:gsub('[%s%(%)]+', '_'):gsub('_+$', ''))]
	if (fn) then
		local ok, err = pcall(fn, value)
		if (not ok) then print('Roku Bridge: property ' .. strProperty .. ' failed: ' .. tostring(err)) end
	end
end

function OnDriverInit() end

function OnDriverLateInit()
	KillAllTimers()
	pcall(function() C4:urlSetTimeout(8) end)
	C4:AddVariable('LAST_LAUNCHED_TITLE', '', 'STRING', true, false)
	C4:AddVariable('LAST_LAUNCHED_APP', '', 'STRING', true, false)
	C4:AddVariable('ACTIVE_APP', '', 'STRING', true, false)
	C4:AddVariable('ROKU_ONLINE', 'false', 'STRING', true, false)
	C4:UpdateProperty('Driver Version', DRIVER_VERSION)
	CheckDriverFile()
	for name, _ in pairs(Properties) do OnPropertyChanged(name) end
end

function OnDriverDestroyed()
	KillAllTimers()
end
