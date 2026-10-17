--[[
    goreader/services/websocket.lua - a WebSocket client (RFC 6455) in pure Lua.

    No dependencies and no bit library: LuaJIT on the reader has `bit`, plain
    Lua 5.1 does not, and the tests run on whatever Lua the Mac has, so masking
    and SHA-1 are done with arithmetic. Messages are tiny, speed is irrelevant.

    Pieces
        WS.sha1, WS.base64_encode/decode, WS.accept_key
        WS.handshake_request / WS.check_handshake
        WS.encode(opcode, payload, mask)         one client frame
        WS.Parser                                bytes in, messages out
        WS.Conn                                  socket + handshake + polling

    The socket is injected so the same code runs over LuaSec on the device and
    over a script in the tests:
        sock:send(bytes)   -> true | nil, err
        sock:receive()     -> bytes | nil, "timeout" | "closed"   (non-blocking)
        sock:close()

    WS.koreader_socket(host, port) builds a TLS socket from LuaSocket+LuaSec;
    it is not exercised by the tests.
--]]

local WS = {}

WS.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS.OP = { CONT = 0, TEXT = 1, BINARY = 2, CLOSE = 8, PING = 9, PONG = 10 }

-- ---------------------------------------------------------------------------
-- Bit helpers (32-bit, arithmetic only)
-- ---------------------------------------------------------------------------

local floor = math.floor
local P32 = 4294967296

local function bitop(a, b, f)
    local r, bit = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if f(x, y) == 1 then r = r + bit end
        a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return r
end

local function band(a, b) return bitop(a, b, function(x, y) return x * y end) end
local function bor(a, b)  return bitop(a, b, function(x, y) return (x + y > 0) and 1 or 0 end) end
local function bxor(a, b) return bitop(a, b, function(x, y) return (x ~= y) and 1 or 0 end) end
local function bnot(a) return P32 - 1 - a end
local function rol(a, n) return (a * 2 ^ n) % P32 + floor(a / 2 ^ (32 - n)) end

local function xor_byte(a, b)
    local r, bit = 0, 1
    for _ = 1, 8 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + bit end
        a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return r
end

-- ---------------------------------------------------------------------------
-- SHA-1 and Base64
-- ---------------------------------------------------------------------------

function WS.sha1(msg)
    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    local len = #msg
    msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
    local bits = len * 8
    local tail = {}
    for i = 7, 0, -1 do tail[#tail + 1] = string.char(floor(bits / 256 ^ i) % 256) end
    msg = msg .. table.concat(tail)

    for chunk = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for i = 16, 79 do
            w[i] = rol(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then f = bor(band(b, c), band(bnot(b), d)); k = 0x5A827999
            elseif i < 40 then f = bxor(bxor(b, c), d); k = 0x6ED9EBA1
            elseif i < 60 then f = bor(bor(band(b, c), band(b, d)), band(c, d)); k = 0x8F1BBCDC
            else f = bxor(bxor(b, c), d); k = 0xCA62C1D6 end
            local temp = (rol(a, 5) + f + e + k + w[i]) % P32
            e, d, c, b, a = d, c, rol(b, 30), a, temp
        end
        h0, h1, h2, h3, h4 = (h0 + a) % P32, (h1 + b) % P32, (h2 + c) % P32, (h3 + d) % P32, (h4 + e) % P32
    end
    local out = {}
    for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
        for i = 3, 0, -1 do out[#out + 1] = string.char(floor(h / 256 ^ i) % 256) end
    end
    return table.concat(out)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function WS.base64_encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = (a * 256 + (b or 0)) * 256 + (c or 0)
        local c1, c2, c3, c4 = floor(n / 262144) % 64, floor(n / 4096) % 64, floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

function WS.base64_decode(text)
    text = text:gsub("[^%w%+/=]", "")
    local out = {}
    for i = 1, #text, 4 do
        local n, pad = 0, 0
        for j = 0, 3 do
            local ch = text:sub(i + j, i + j)
            local v
            if ch == "=" or ch == "" then v = 0; pad = pad + 1 else v = B64:find(ch, 1, true) - 1 end
            n = n * 64 + v
        end
        local s = string.char(floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
        out[#out + 1] = s:sub(1, 3 - pad)
    end
    return table.concat(out)
end

function WS.accept_key(key)
    return WS.base64_encode(WS.sha1(key .. WS.GUID))
end

-- ---------------------------------------------------------------------------
-- Handshake
-- ---------------------------------------------------------------------------

--[[ A random 16-byte key, base64. `rand` is math.random-like (default math.random). ]]
function WS.make_key(rand)
    rand = rand or math.random
    local b = {}
    for i = 1, 16 do b[i] = string.char(rand(0, 255)) end
    return WS.base64_encode(table.concat(b))
end

--[[ opts: host, path (default "/"), key, origin, headers = { name = value } ]]
function WS.handshake_request(opts)
    local lines = {
        "GET " .. (opts.path or "/") .. " HTTP/1.1",
        "Host: " .. opts.host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. opts.key,
        "Sec-WebSocket-Version: 13",
    }
    if opts.origin then lines[#lines + 1] = "Origin: " .. opts.origin end
    local names = {}
    for k in pairs(opts.headers or {}) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do lines[#lines + 1] = k .. ": " .. opts.headers[k] end
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

--[[ Check the server's reply. Returns true, leftover (bytes after the header
     that already belong to the frame stream) | nil, reason | false, "incomplete" ]]
function WS.check_handshake(response, key)
    local head_end = response:find("\r\n\r\n", 1, true)
    if not head_end then return false, "incomplete" end
    local head = response:sub(1, head_end + 1)
    local leftover = response:sub(head_end + 4)
    local status = head:match("^HTTP/%d%.%d (%d+)")
    if status ~= "101" then return nil, "handshake refused (HTTP " .. tostring(status) .. ")" end
    local headers = {}
    for name, value in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[name:lower()] = value
    end
    if (headers["upgrade"] or ""):lower() ~= "websocket" then return nil, "no websocket upgrade" end
    if headers["sec-websocket-accept"] ~= WS.accept_key(key) then
        return nil, "bad Sec-WebSocket-Accept"
    end
    return true, leftover
end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

--[[ Encode one client frame (clients must mask). `mask` is 4 bytes (string).
     fin defaults to true. ]]
function WS.encode(opcode, payload, mask, fin)
    payload = payload or ""
    assert(type(mask) == "string" and #mask == 4, "a 4-byte mask is required")
    local n = #payload
    local b0 = (fin == false and 0 or 128) + opcode
    local head
    if n < 126 then head = string.char(b0, 128 + n)
    elseif n < 65536 then head = string.char(b0, 128 + 126, floor(n / 256), n % 256)
    else
        local lens = {}
        for i = 7, 0, -1 do lens[#lens + 1] = string.char(floor(n / 256 ^ i) % 256) end
        head = string.char(b0, 128 + 127) .. table.concat(lens)
    end
    local masked = {}
    local m1, m2, m3, m4 = mask:byte(1, 4)
    local mb = { m1, m2, m3, m4 }
    for i = 1, n do
        masked[i] = string.char(xor_byte(payload:byte(i), mb[(i - 1) % 4 + 1]))
    end
    return head .. mask .. table.concat(masked)
end

local Parser = {}
Parser.__index = Parser
WS.Parser = Parser

function Parser.new(opts)
    return setmetatable({ buf = "", fragments = nil, frag_op = nil,
                          max_size = (opts and opts.max_size) or (4 * 1024 * 1024) }, Parser)
end

-- Try to read one frame from the buffer. Returns frame or nil (need more) or nil,err.
function Parser:_frame()
    local buf = self.buf
    if #buf < 2 then return nil end
    local b0, b1 = buf:byte(1, 2)
    local fin = b0 >= 128
    local rsv = floor(b0 / 16) % 8
    local opcode = b0 % 16
    if rsv ~= 0 then return nil, "reserved bits set" end
    local masked = b1 >= 128
    local len = b1 % 128
    local pos = 3
    if len == 126 then
        if #buf < 4 then return nil end
        local a, b = buf:byte(3, 4); len = a * 256 + b; pos = 5
    elseif len == 127 then
        if #buf < 10 then return nil end
        len = 0
        for i = 3, 10 do len = len * 256 + buf:byte(i) end
        pos = 11
    end
    if len > self.max_size then return nil, "frame too large" end
    local mask
    if masked then
        if #buf < pos + 3 then return nil end
        mask = { buf:byte(pos, pos + 3) }; pos = pos + 4
    end
    if #buf < pos + len - 1 then return nil end
    local payload = buf:sub(pos, pos + len - 1)
    if mask then
        local t = {}
        for i = 1, len do t[i] = string.char(xor_byte(payload:byte(i), mask[(i - 1) % 4 + 1])) end
        payload = table.concat(t)
    end
    self.buf = buf:sub(pos + len)
    return { fin = fin, opcode = opcode, payload = payload }
end

--[[ Feed bytes; returns a list of complete messages { opcode, payload } and
     an error string if the stream is broken. Control frames (ping, pong,
     close) are returned as they arrive, even between fragments. ]]
function Parser:feed(bytes)
    self.buf = self.buf .. (bytes or "")
    local out = {}
    while true do
        local f, err = self:_frame()
        if err then return out, err end
        if not f then break end
        if f.opcode >= 8 then
            if not f.fin or #f.payload > 125 then return out, "bad control frame" end
            out[#out + 1] = { opcode = f.opcode, payload = f.payload }
        elseif f.opcode == 0 then
            if not self.fragments then return out, "unexpected continuation" end
            self.fragments[#self.fragments + 1] = f.payload
            if f.fin then
                out[#out + 1] = { opcode = self.frag_op, payload = table.concat(self.fragments) }
                self.fragments, self.frag_op = nil, nil
            end
        else
            if self.fragments then return out, "new message inside a fragmented one" end
            if f.fin then
                out[#out + 1] = { opcode = f.opcode, payload = f.payload }
            else
                self.fragments, self.frag_op = { f.payload }, f.opcode
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn
WS.Conn = Conn

--[[ opts: socket (required), host, path, origin, headers, rand
     Call :open() then :poll() regularly. ]]
function WS.new(opts)
    assert(opts.socket and opts.host, "socket and host are required")
    local rand = opts.rand or math.random
    return setmetatable({
        sock = opts.socket, host = opts.host, path = opts.path or "/",
        origin = opts.origin, headers = opts.headers, rand = rand,
        parser = Parser.new(), state = "new", queue = {}, close_code = nil,
    }, Conn)
end

function Conn:_mask()
    local b = {}
    for i = 1, 4 do b[i] = string.char(self.rand(0, 255)) end
    return table.concat(b)
end

function Conn:_send_frame(op, payload)
    local ok, err = self.sock:send(WS.encode(op, payload, self:_mask()))
    if not ok then self.state = "closed"; return nil, err or "send failed" end
    return true
end

--[[ Do the opening handshake. Blocking up to `tries` polls of the socket
     (each poll is the socket's own timeout). Returns true or nil, err. ]]
function Conn:open(tries)
    self.key = WS.make_key(self.rand)
    local ok, err = self.sock:send(WS.handshake_request{
        host = self.host, path = self.path, key = self.key,
        origin = self.origin, headers = self.headers })
    if not ok then return nil, "cannot send handshake: " .. tostring(err) end
    local acc = ""
    for _ = 1, tries or 50 do
        local data, rerr = self.sock:receive()
        if data and data ~= "" then
            acc = acc .. data
            local res, extra = WS.check_handshake(acc, self.key)
            if res == true then
                self.state = "open"
                local msgs, perr = self.parser:feed(extra)
                self:_dispatch(msgs)
                if perr then return nil, perr end
                return true
            elseif res == nil then
                self.sock:close(); self.state = "closed"
                return nil, extra
            end
        elseif rerr == "closed" then
            self.state = "closed"
            return nil, "connection closed during handshake"
        end
    end
    self.sock:close(); self.state = "closed"
    return nil, "handshake timed out"
end

function Conn:_dispatch(msgs)
    for _, m in ipairs(msgs) do
        if m.opcode == WS.OP.PING then
            self:_send_frame(WS.OP.PONG, m.payload)
        elseif m.opcode == WS.OP.CLOSE then
            local code = #m.payload >= 2 and (m.payload:byte(1) * 256 + m.payload:byte(2)) or 1005
            self.close_code = code
            if self.state == "open" then
                self:_send_frame(WS.OP.CLOSE, m.payload:sub(1, 2))
            end
            self.state = "closed"
            self.sock:close()
        elseif m.opcode == WS.OP.TEXT or m.opcode == WS.OP.BINARY then
            self.queue[#self.queue + 1] = m.payload
        end
    end
end

--[[ Read whatever has arrived. Returns the list of text messages received
     (possibly empty), then "closed" as a second value when the connection ended. ]]
function Conn:poll()
    if self.state == "open" then
        for _ = 1, 20 do                              -- drain, but never spin
            local data, err = self.sock:receive()
            if data and data ~= "" then
                local msgs, perr = self.parser:feed(data)
                self:_dispatch(msgs)
                if perr then
                    self:close(1002)
                    break
                end
            else
                if err == "closed" then self.state = "closed" end
                break
            end
            if self.state ~= "open" then break end
        end
    end
    local out = self.queue
    self.queue = {}
    return out, self.state == "closed" and "closed" or nil
end

function Conn:send_text(text)
    if self.state ~= "open" then return nil, "not_open" end
    return self:_send_frame(WS.OP.TEXT, text)
end

function Conn:ping(payload)
    if self.state ~= "open" then return nil, "not_open" end
    return self:_send_frame(WS.OP.PING, payload or "")
end

function Conn:close(code)
    if self.state == "open" then
        code = code or 1000
        self:_send_frame(WS.OP.CLOSE, string.char(floor(code / 256), code % 256))
    end
    self.state = "closed"
    self.sock:close()
end

function Conn:is_open() return self.state == "open" end

-- ---------------------------------------------------------------------------
-- KOReader socket (LuaSocket + LuaSec). Not covered by the tests.
-- ---------------------------------------------------------------------------

function WS.koreader_socket(host, port, timeout)
    local socket = require("socket")
    local ssl    = require("ssl")
    local raw, err = socket.tcp()
    if not raw then return nil, err end
    raw:settimeout(timeout or 10)
    local ok, cerr = raw:connect(host, port or 443)
    if not ok then raw:close(); return nil, cerr end
    local tls, werr = ssl.wrap(raw, { mode = "client", protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3" }, verify = "none" })
    if not tls then raw:close(); return nil, werr end
    tls:sni(host)
    local hok, herr = tls:dohandshake()
    if not hok then tls:close(); return nil, herr end
    tls:settimeout(0)                                  -- polling from here on
    local S = {}
    function S:send(data)
        local i = 1
        while i <= #data do
            local sent, serr, partial = tls:send(data, i)
            if sent then i = sent + 1
            elseif serr == "wantwrite" or serr == "timeout" then i = (partial or i - 1) + 1
            else return nil, serr end
        end
        return true
    end
    function S:receive()
        local data, rerr, partial = tls:receive(8192)
        if data then return data end
        if partial and partial ~= "" then return partial end
        if rerr == "timeout" or rerr == "wantread" then return nil, "timeout" end
        return nil, "closed"
    end
    function S:close() pcall(function() tls:close() end) end
    return S
end

return WS
