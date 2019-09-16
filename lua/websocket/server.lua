local websocket = websocket
local frame = websocket.frame
local utilities = websocket.utilities

local socket = require("socket") or socket

local insert, remove, concat = table.insert, table.remove, table.concat
local format = string.format
local setmetatable, assert, print = setmetatable, assert, print
local hook_Add, hook_Remove = hook.Add, hook.Remove

local Base64Encode, SHA1 = utilities.Base64Encode, utilities.SHA1
local HTTPHeaders, XORMask = utilities.HTTPHeaders, utilities.XORMask
local Encode, DecodeHeader = frame.Encode, frame.DecodeHeader

local state = websocket.state
local CONNECTING, OPEN, CLOSED = state.CONNECTING, state.OPEN, state.CLOSED

local CONNECTION = {}
CONNECTION.__index = CONNECTION

function CONNECTION:SetReceiveCallback(func)
	self.recvcallback = func
end

function CONNECTION:Shutdown()
	if not self:IsValid() then
		return
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil
end

function CONNECTION:IsValid()
	return self.socket ~= nil
end

function CONNECTION:GetRemoteAddress()
	if not self:IsValid() then
		return "", 0
	end

	return self.socket:getsockname()
end

function CONNECTION:GetState()
	return self.state
end

function CONNECTION:Send(data, opcode, masked, fin)
	if not self:IsValid() then
		return false
	end

	local data = Encode(data, opcode, masked, fin)
	return self.socket:send(data) == #data
end

function CONNECTION:Receive(pattern)
	if not self:IsValid() then
		return false
	end

	local data, err, part = self.socket:receive(pattern)
	if err == "closed" then
		self.socket = nil
		self.state = CLOSED
	end

	return err and part or data, err
end

function CONNECTION:ReceiveEx(len)
	local out = ""
	local err,buf

	while len > 0 do
		buf,err = self:Receive(len)

		if not err then
			out = out..buf
			len = len - #buf
		elseif err ~= "timeout" then
			return err
		end

		coroutine.yield()
	end

	return nil,out
end

function CONNECTION:ReadFrame()
	-- Based off https://github.com/lipp/lua-websockets/blob/master/src/websocket/sync.lua#L8
	local first_opcode
	local frames
	local bytes = 3
	local encoded = ''

	local clean = function(was_clean,code,reason)
		self.state = state.CLOSED
		self:Shutdown()
		return nil,nil,was_clean,code,reason or "closed"
	end

	while true do
		local err,chunk = self:ReceiveEx(bytes - #encoded)
		if err then
			return clean(false,1006,err)
		end
		encoded = encoded..chunk
		local decoded,length,opcode,masked,fin,mask = DecodeHeader(encoded)
		if decoded then
			err,decoded = self:ReceiveEx(length)
			if masked then
				decoded = XORMask(decoded,mask)
			end

			assert(not err,"ReadFrame() -> ReceiveEx() error")
			if opcode == frame.CLOSE then
				error("TODO: websocket close opcode")
			end
			if not first_opcode then
				first_opcode = opcode
			end
			if not fin then
				if not frames then
					frames = {}
				elseif opcode ~= frame.CONTINUATION then
					return clean(false,1002,"protocol error")
				end
				bytes = 3
				encoded = ""
				insert(frames,decoded)
			elseif not frames then
				return decoded,first_opcode
			else
				insert(frames,decoded)
				return concat(frames),first_opcode
			end
		else
			assert(type(length) == "number" and length > 0)
			bytes = length
		end
	end
end

function CONNECTION:ThinkFactory()
	if not self:IsValid() then
		return
	end

	if self.state == CONNECTING then
		local httpData = {}
		local data, err = self:Receive()
		while data ~= nil and err == nil do
			insert(httpData, data)

			if #data == 0 then
				break
			end

			data, err = self:Receive()
		end

		if err == nil then
			httpData = HTTPHeaders(httpData)
			if httpData ~= nil then
				local wsKey = httpData.headers["sec-websocket-key"]

				if wsKey then
					local key = format(
						"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: %s\r\nSec-WebSocket-Accept: %s\r\n\r\n",
						httpData.headers["connection"],
						Base64Encode(SHA1(
							httpData.headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
						))
					)
					self.state = self.socket:send(key) == #key and OPEN or CLOSED
				else
					-- could do a callback to allow the user to customise the response
					-- but this is a **websocket** server library, not a http server library
					-- so I believe this is out of scope.
					self.socket:send(format(
						"HTTP/1.1 200 OK\r\nConnection: %s\r\n\r\nHello, you have reached gm_websocket :)\r\n\r\n",
						httpData.headers["connection"]
					))
					self:Shutdown()
				end
			end
		else
			print("websocket auth error: " .. err)
		end
	elseif self.state == OPEN then
		local decoded,firstOpcode = self:ReadFrame()
		if decoded and self.recvcallback then
			self.recvcallback(self, decoded)
		end
	end
end

local SERVER = {}
SERVER.__index = SERVER

function SERVER:SetAcceptCallback(func)
	self.acceptcallback = func
end

function SERVER:Shutdown()
	if not self:IsValid() then
		return
	end

	for i = 1, self.numconnections do
		self.connections[i]:Shutdown()
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil

	hook_Remove("Think", self)
end

function SERVER:IsValid()
	return self.socket ~= nil
end

function SERVER:Think()
	if not self:IsValid() then
		return
	end

	local client = self.socket:accept()
	while client ~= nil do
		client:settimeout(0)
		local connection = setmetatable({
			socket = client,
			server = self,
			state = CONNECTING
		}, CONNECTION)

		connection.Think = coroutine.wrap(function(...)
			while true do
				local suc,err = xpcall(connection.ThinkFactory,debug.traceback,...)

				if not suc then
					ErrorNoHalt(err.."\n")
				end

				coroutine.yield()
			end
		end)

		if self.acceptcallback == nil or self.acceptcallback(self, connection) == true then
			insert(self.connections, connection)
			self.numconnections = self.numconnections + 1
		end

		client = self.socket:accept()
	end

	for i = 1, self.numconnections do
		self.connections[i]:Think()
		if self.connections[i]:GetState() == CLOSED then
			remove(self.connections, i)
			self.numconnections = self.numconnections - 1
			i = i - 1
		end
	end
end

function websocket.CreateServer(addr, port, queue) -- non-blocking and max queue of 5 by default
	assert(addr ~= nil and port ~= nil, "address or port not provided to create websocket server")

	local server = setmetatable({
		socket = assert(socket.tcp(), "failed to create socket"),
		numconnections = 0,
		connections = {}
	}, SERVER)
	server.socket:settimeout(0)
	assert(server.socket:bind(addr, port) == 1,"failed to bind address/port")
	server.socket:listen(queue or 5)

	hook_Add("Think", server, SERVER.Think)

	return server
end
