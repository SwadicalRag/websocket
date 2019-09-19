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
local Encode, DecodeHeader, EncodeClose, DecodeClose = frame.Encode, frame.DecodeHeader, frame.EncodeClose, frame.DecodeClose

local state = websocket.state
local CONNECTING, OPEN, CLOSED = state.CONNECTING, state.OPEN, state.CLOSED

local CONNECTION = {}
CONNECTION.__index = CONNECTION

function CONNECTION:SetReceiveCallback(func)
	self.recvcallback = func
end

function CONNECTION:SetCloseCallback(func)
	self.closecallback = func
end

function CONNECTION:SetErrorCallback(func)
	self.errorcallback = func
end

function CONNECTION:Shutdown(code,reason)
	if self.is_closing then return end

	code = code or 1000

	self:ShutdownInternal(code,reason)

	if not self.socket then return end
	
	local closeFrame = EncodeClose(code,reason)
	local fullCloseFrame = Encode(closeFrame, frame.CLOSE, false, true)

	local sentLen,err = self.socket:send(fullCloseFrame)

	if err then
		return false,err
	elseif (sentLen ~= #fullCloseFrame) then
		return false,"incomplete send"
	else
		return true
	end
end

function CONNECTION:ShutdownInternal(code,reason)
	if not self:IsValid() then
		return
	end

	if self.is_closing then return end

	self.is_closing = true

	if self.closecallback then
		self.closecallback(self,code,reason)
	end

	if not self.socket then return end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil
	self.state = CLOSED
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

function CONNECTION:Send(data, opcode)
	if not self:IsValid() then
		return false
	end

	local data = Encode(data, opcode, false, true)
	return self.socket:send(data) == #data
end

function CONNECTION:SendEx(data, opcode)
	if not self:IsValid() then
		return false
	end

	local data = Encode(data, opcode, false, true)
	self.sendBuffer[#self.sendBuffer + 1] = data
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
		elseif (type(buf) == "string") and #buf > 0 then
			-- timeout but we were able to read some stuff
			out = out..buf
			len = len - #buf
		end

		if len > 0 then
			coroutine.yield(false,"read block")
		end
	end

	return nil,out
end

-- Include should return properly in an up-to-date gmod
CONNECTION.ReadFrame = include("readframe.vendor.lua")

function CONNECTION:ThinkFactory()
	if not self:IsValid() then
		return false,"closed"
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

					self.socket:shutdown("both")
					self.socket:close()
					self.socket = nil
				end
			end
		else
			if self.errorcallback then
				self.errorcallback(self,"websocket auth error: " .. err)
			end
		end

		return true
	elseif self.state == OPEN then
		local suc,messages = self:ReadFrame()
		if suc then
			if self.recvcallback then
				for i,msg in ipairs(messages) do
					self.recvcallback(self,msg.data,msg.opcode,msg.masked,msg.fin)
				end
			end

			return true
		else
			-- `messages` is error string on failure cases
			return false,messages
		end
	end
end

local SERVER = {}
SERVER.__index = SERVER

function SERVER:SetAcceptCallback(func)
	self.acceptcallback = func
end

function SERVER:Shutdown(code,reason)
	if not self:IsValid() then
		return
	end

	for i = 1, self.numconnections do
		self.connections[i]:ShutdownInternal(code,reason)
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

	for i,connection in ipairs(self.connections) do
		while #connection.sendBuffer > 0 do
			local toSend = connection.sendBuffer[1]
			local sentLen,err = connection.socket:send(toSend)

			if err then
				if connection.errorcallback then
					connection.errorcallback(connection,"websocket auth error: " .. err)
				end
			elseif #toSend == sentLen then
				table.remove(connection.sendBuffer,1)
			else
				connection.sendBuffer[1] = toSend:sub(sentLen + 1,-1)
			end
		end
	end

	local client = self.socket:accept()
	while client ~= nil do
		client:settimeout(0)
		local connection = setmetatable({
			socket = client,
			server = self,
			state = CONNECTING,
			sendBuffer = {},
		}, CONNECTION)

		connection.Think = coroutine.wrap(function(...)
			while true do
				::tryAgain::
				local suc,ret,reason = xpcall(connection.ThinkFactory,debug.traceback,...)

				if not suc then
					ErrorNoHalt(ret.."\n")
				elseif ret then
					-- we were able to read a packet!
					-- try read another if we can!
					goto tryAgain
				elseif connection.socket and connection.socket:dirty() then
					-- theres still more data!
					goto tryAgain
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
		if (self.connections[i]:GetState() == CLOSED) or (self.connections[i].socket == nil) then
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
