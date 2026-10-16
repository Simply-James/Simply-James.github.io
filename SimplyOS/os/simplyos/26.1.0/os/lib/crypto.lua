-- /os/lib/crypto.lua
-- sha256 and HMAC-SHA256 (standard). Pure Lua, accelerator used for large data when it matches.
local M = {}
local band, bxor, rshift, lshift, rrot, bnot = bit32.band, bit32.bxor, bit32.rshift, bit32.lshift, bit32.rrotate, bit32.bnot
local K = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 }

local function wordsToBytes(h)
    local t = {}
    for i = 1, 8 do
        local v = h[i]
        t[#t + 1] = string.char(rshift(v, 24), band(rshift(v, 16), 255), band(rshift(v, 8), 255), band(v, 255))
    end
    return table.concat(t)
end

local function pure(msg)
    local len = #msg
    local bits = len * 8
    local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
    msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) ..
        string.char(rshift(hi, 24), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
                    rshift(lo, 24), band(rshift(lo, 16), 255), band(rshift(lo, 8), 255), band(lo, 255))
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i + 1] = a * 16777216 + b * 65536 + c * 256 + d
        end
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(rrot(x, 7), rrot(x, 18), rshift(x, 3))
            local s1 = bxor(rrot(y, 17), rrot(y, 19), rshift(y, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (hh + S1 + ch + K[i] + w[i]) % 4294967296
            local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = (S0 + maj) % 4294967296
            hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
        end
        h[1] = (h[1] + a) % 4294967296; h[2] = (h[2] + b) % 4294967296
        h[3] = (h[3] + c) % 4294967296; h[4] = (h[4] + d) % 4294967296
        h[5] = (h[5] + e) % 4294967296; h[6] = (h[6] + f) % 4294967296
        h[7] = (h[7] + g) % 4294967296; h[8] = (h[8] + hh) % 4294967296
    end
    return wordsToBytes(h)
end

function M.toHex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.fromHex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

function M.sha256Raw(s) return pure(s) end

local accel, checked = nil, false
local function norm(r)
    if type(r) ~= "string" then return nil end
    if #r == 64 and r:match("^%x+$") then return r:lower() end
    if #r == 32 then return M.toHex(r) end
    return nil
end
local function getAccel()
    if checked then return accel end
    checked = true
    pcall(function()
        local p = peripheral.find("cryptographic_accelerator")
        if not p then return end
        local long = string.rep("0123456789abcdef", 20)
        if norm(p.sha256("abc")) == M.toHex(pure("abc")) and norm(p.sha256(long)) == M.toHex(pure(long)) then accel = p end
    end)
    return accel
end

function M.sha256(s)
    s = tostring(s)
    if #s > 4000 then
        local a = getAccel()
        if a then
            local ok, r = pcall(a.sha256, s)
            if ok and norm(r) then return norm(r) end
        end
    end
    return M.toHex(pure(s))
end

function M.hmacRaw(key, msg)
    key, msg = tostring(key), tostring(msg)
    if #key > 64 then key = pure(key) end
    key = key .. string.rep("\0", 64 - #key)
    local ik = key:gsub(".", function(c) return string.char(bxor(c:byte(), 0x36)) end)
    local ok = key:gsub(".", function(c) return string.char(bxor(c:byte(), 0x5c)) end)
    return pure(ok .. pure(ik .. msg))
end

function M.hmac(key, msg) return M.toHex(M.hmacRaw(key, msg)) end

local seeded = false
function M.randomBytes(n)
    if not seeded then math.randomseed(os.epoch("utc") + math.floor(os.clock() * 1000)); seeded = true end
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

return M
