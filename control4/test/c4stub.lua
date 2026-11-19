-- Minimal stand-in for the DriverWorks "C4" runtime so driver.lua can be
-- loaded and exercised under plain Lua 5.1. Only the calls the driver makes
-- are implemented; each one records what it was asked to do so tests can
-- assert on it.

local stub = {}

C4 = {}
Properties = Properties or {}
PersistData = PersistData or {}
Variables = Variables or {}

stub.log = {}                 -- every C4 call, in order
stub.timers = {}              -- pending timers {delay, fn, repeating, id}
stub.urlRequests = {}         -- outstanding HTTP requests
stub.proxyMessages = {}       -- C4:SendToProxy calls
stub.deviceMessages = {}      -- C4:SendToDevice calls
stub.properties = Properties
stub.boundProvider = {}       -- [bindingId] = deviceId
stub.proxyDeviceId = 777
stub.deviceId = 778
stub.wol = {}
stub.events = {}
stub.variables = {}

local function record(name, ...)
	table.insert(stub.log, { name = name, args = { ... } })
end

local nextTimerId = 0
local TimerMT = {}
TimerMT.__index = TimerMT
function TimerMT:Cancel()
	for i, t in ipairs(stub.timers) do
		if (t == self) then table.remove(stub.timers, i) break end
	end
	return nil
end

function C4:SetTimer(ms, fn, repeating)
	nextTimerId = nextTimerId + 1
	local t = setmetatable({ delay = ms, fn = fn, repeating = repeating, id = nextTimerId }, TimerMT)
	table.insert(stub.timers, t)
	record("SetTimer", ms, repeating)
	return t
end

-- Fire every pending timer once (repeating timers stay registered).
function stub.fireTimers()
	local pending = {}
	for _, t in ipairs(stub.timers) do table.insert(pending, t) end
	for _, t in ipairs(pending) do
		if (not t.repeating) then t:Cancel() end
		t.fn(t)
	end
end

function C4:urlGet(url, headers, bSSLVerify, callback)
	record("urlGet", url)
	table.insert(stub.urlRequests, { method = "GET", url = url, headers = headers, callback = callback })
	return #stub.urlRequests
end

function C4:urlPost(url, data, headers, bSSLVerify, callback)
	record("urlPost", url, data)
	table.insert(stub.urlRequests, { method = "POST", url = url, data = data, headers = headers, callback = callback })
	return #stub.urlRequests
end

-- Complete the oldest outstanding HTTP request with the given response.
function stub.respond(code, body, err)
	local req = table.remove(stub.urlRequests, 1)
	assert(req, "no outstanding url request")
	req.callback(1, body, code, { ["Content-Type"] = "application/json" }, err)
	return req
end

function C4:urlSetTimeout(s) record("urlSetTimeout", s) end

function C4:SendToProxy(idBinding, strCommand, tParams, strMessage, allowEmpty)
	record("SendToProxy", idBinding, strCommand)
	table.insert(stub.proxyMessages, { binding = idBinding, command = strCommand, params = tParams, message = strMessage })
end

function C4:SendToDevice(deviceId, strCommand, tParams)
	record("SendToDevice", deviceId, strCommand)
	table.insert(stub.deviceMessages, { device = deviceId, command = strCommand, params = tParams })
end

function C4:UpdateProperty(name, value)
	record("UpdateProperty", name, value)
	Properties[name] = value
end

function C4:UpdatePropertyList(name, list, default)
	record("UpdatePropertyList", name, list)
end

function C4:GetProxyDevices() return stub.proxyDeviceId end
function C4:GetDeviceID() return stub.deviceId end
function C4:GetBoundProviderDevice(deviceId, idBinding) return stub.boundProvider[idBinding] end
stub.proxyIds = { [5001] = 777, [5002] = 780 }
function C4:GetBoundConsumerDevices(deviceId, idBinding)
	local id = stub.proxyIds[tonumber(idBinding)]
	if (id) then return { [id] = 'proxy' } end
	return { [999] = "TV" }
end
function C4:GetDriverConfigInfo(tag) return "0.1.0" end
function C4:GetControllerNetworkAddress() return "192.168.1.2" end

function C4:AddVariable(name, value, vtype, readonly, hidden)
	record("AddVariable", name)
	stub.variables[name] = value
end
function C4:SetVariable(name, value)
	record("SetVariable", name, value)
	stub.variables[name] = value
end

function C4:FireEvent(name)
	record("FireEvent", name)
	table.insert(stub.events, name)
end

function C4:SendWOL(mac, port)
	record("SendWOL", mac)
	table.insert(stub.wol, mac)
end

function C4:Base64Encode(s)
	local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	return ((s:gsub('.', function(x)
		local r, byte = '', x:byte()
		for i = 8, 1, -1 do r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and '1' or '0') end
		return r
	end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
		if (#x < 6) then return '' end
		local c = 0
		for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
		return b:sub(c + 1, c + 1)
	end) .. ({ '', '==', '=' })[#s % 3 + 1])
end

-- The real ParseXml returns a node tree; the driver only needs ARGS parsing,
-- which it does with string patterns, so this is deliberately minimal.
function C4:ParseXml(xml)
	local node = { ChildNodes = {} }
	for name, value in string.gmatch(xml, '<param[^>]-name="([^"]-)"[^>]*>(.-)</param>') do
		table.insert(node.ChildNodes, { Attributes = { name = name }, Value = value })
	end
	return node
end

function C4:ErrorLog(s) record("ErrorLog", s) end
function C4:RegisterVariableListener() end
function C4:UnregisterVariableListener() end
function C4:GetDevicesByC4iName() return {} end
stub.roomDevice = {}            -- [roomId] = proxy device id currently selected
function C4:GetDeviceVariable(deviceId, idVariable)
	if (idVariable == 1000) then return stub.roomDevice[tonumber(deviceId)] or 0 end
	return 0
end

return stub
