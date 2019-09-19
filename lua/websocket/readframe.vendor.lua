
-- https://github.com/lipp/lua-websockets/blob/cafb5874473ab9f54e734c123b18fb059801e4d5/src/websocket/sync.lua#L8-L75
--[[
    Copyright (c) 2012 by Gerhard Lipp <gelipp@gmail.com>

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.
]]

local insert, remove, concat = table.insert, table.remove, table.concat

local websocket = websocket
local frame = websocket.frame
local utilities = websocket.utilities

local XORMask = utilities.XORMask
local Encode, DecodeHeader, EncodeClose, DecodeClose = frame.Encode, frame.DecodeHeader, frame.EncodeClose, frame.DecodeClose

local state = websocket.state

local function ReadFrame(self)
    -- modified with error callbacks
    -- and to work with a coroutine-based receive function
    -- and also modified the return values to make actual sense.

	if self.is_closing then return false,"closing" end

	local startOpcode
	local readFrames
	local bytesToRead = 2
	local encodedMsg = ""

	local clean = function(wasCleanExit,code,reason)
		self.state = state.CLOSED
		self:ShutdownInternal(code,reason)
		if not wasCleanExit then
			if self.errorcallback then
				self.errorcallback(self,"websocket close error: " .. tostring(reason))
			end
		end
		return false,reason or "closed",wasCleanExit,code
	end

	while true do
		local err,chunk = self:ReceiveEx(bytesToRead - #encodedMsg)
		if err then
			return clean(false,1006,err)
		end

		encodedMsg = encodedMsg..chunk

		local decoded,length,opcode,masked,fin,mask,headerLen = DecodeHeader(encodedMsg)
		if decoded then
			err,decoded = self:ReceiveEx(length - (#encodedMsg - headerLen))

			if #encodedMsg > headerLen then decoded = encodedMsg:sub(headerLen + 1, -1)..decoded end
			if masked then
				decoded = XORMask(decoded,mask)
			end

			assert(not err,"ReadFrame() -> ReceiveEx() error")
			if opcode == frame.CLOSE then
				if not self.is_closing then
					self.is_closing = true
					
					local code,reason = DecodeClose(decoded)
					local closeFrame = EncodeClose(code,reason)
					local fullCloseFrame = Encode(closeFrame, frame.CLOSE, false, true)

					local sentLen,err = self.socket:send(fullCloseFrame)

					if err or (sentLen ~= #fullCloseFrame) then
						return clean(false,code,err)
					else
						return clean(true,code,reason)
					end
				else
					return decoded,opcode,masked,fin
				end
			elseif opcode == frame.PING then
				local pongFrame = Encode(decoded, frame.PONG, false, true)

				local sentLen,err = self.socket:send(pongFrame)

				if err or (sentLen ~= #pongFrame) then
					return clean(false,code,err)
				end

				return decoded,opcode,masked,fin
			elseif opcode == frame.PONG then
				return decoded,opcode,masked,fin
			end

			if not startOpcode then
				startOpcode = opcode
			end
			if not fin then
				if not readFrames then
					readFrames = {}
				elseif opcode ~= frame.CONTINUATION then
					return clean(false,1002,"protocol error")
				end
				bytesToRead = 3
				encodedMsg = ""
				insert(readFrames,decoded)
			elseif not readFrames then
				return decoded,startOpcode,masked,fin
			else
				insert(readFrames,decoded)
				return concat(readFrames),startOpcode,masked,fin
			end
		else
			assert(type(length) == "number" and length > 0)
			bytesToRead = length
		end
	end
end

return ReadFrame
