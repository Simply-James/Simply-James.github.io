-- /os/lib/cipher.lua
-- Message sealing: hex(nonce8 .. AES-128-CTR(plain) .. tag16). Spec: ROOT_SERVER_DEVDOC_ADDENDUM section 2.
-- If the server project ships its own cipher.lua, copy it over this file unchanged.
local crypto = dofile("/os/lib/crypto.lua")
local M = {}
local band, bxor, lshift, rshift = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift

local sbox = {}
do
    local p, q = 1, 1
    repeat
        p = bxor(p, band(lshift(p, 1), 255), (band(p, 128) ~= 0) and 0x1B or 0)
        q = bxor(q, band(lshift(q, 1), 255))
        q = bxor(q, band(lshift(q, 2), 255))
        q = bxor(q, band(lshift(q, 4), 255))
        if band(q, 128) ~= 0 then q = bxor(q, 0x09) end
        local function rotl(x, n) return band(bxor(lshift(x, n), rshift(x, 8 - n)), 255) end
        sbox[p] = bxor(q, rotl(q, 1), rotl(q, 2), rotl(q, 3), rotl(q, 4), 0x63)
    until p == 1
    sbox[0] = 0x63
end

local function xtime(a)
    a = lshift(a, 1)
    if a >= 256 then a = bxor(a, 0x11B) end
    return a
end

local function expand(key)
    local w = {}
    for i = 0, 3 do w[i] = { key:byte(i * 4 + 1, i * 4 + 4) } end
    local rcon = 1
    for i = 4, 43 do
        local t = { w[i - 1][1], w[i - 1][2], w[i - 1][3], w[i - 1][4] }
        if i % 4 == 0 then
            t = { sbox[t[2]], sbox[t[3]], sbox[t[4]], sbox[t[1]] }
            t[1] = bxor(t[1], rcon)
            rcon = xtime(rcon)
        end
        local p = w[i - 4]
        w[i] = { bxor(p[1], t[1]), bxor(p[2], t[2]), bxor(p[3], t[3]), bxor(p[4], t[4]) }
    end
    return w
end

local function encryptBlock(w, block)
    local s = { block:byte(1, 16) }
    local function addKey(r)
        for c = 0, 3 do
            local k = w[r * 4 + c]
            for i = 1, 4 do s[c * 4 + i] = bxor(s[c * 4 + i], k[i]) end
        end
    end
    addKey(0)
    for r = 1, 10 do
        for i = 1, 16 do s[i] = sbox[s[i]] end
        -- shift rows (state is column-major: s[c*4+row+1])
        local t = {}
        for c = 0, 3 do
            for row = 0, 3 do t[c * 4 + row + 1] = s[((c + row) % 4) * 4 + row + 1] end
        end
        s = t
        if r < 10 then
            for c = 0, 3 do
                local a0, a1, a2, a3 = s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3], s[c * 4 + 4]
                local x = bxor(a0, a1, a2, a3)
                s[c * 4 + 1] = bxor(a0, x, xtime(bxor(a0, a1)))
                s[c * 4 + 2] = bxor(a1, x, xtime(bxor(a1, a2)))
                s[c * 4 + 3] = bxor(a2, x, xtime(bxor(a2, a3)))
                s[c * 4 + 4] = bxor(a3, x, xtime(bxor(a3, a0)))
            end
        end
        addKey(r)
    end
    return string.char(table.unpack(s))
end
M.encryptBlock = function(key, block) return encryptBlock(expand(key), block) end

local function ctr(keyBytes, nonce8, data)
    local w = expand(keyBytes)
    local out = {}
    local counter = 0
    for i = 1, #data, 16 do
        local c = counter
        local cb = {}
        for b = 8, 1, -1 do cb[b] = c % 256; c = math.floor(c / 256) end
        local ks = encryptBlock(w, nonce8 .. string.char(table.unpack(cb)))
        local chunk = data:sub(i, i + 15)
        local o = {}
        for j = 1, #chunk do o[j] = string.char(bxor(chunk:byte(j), ks:byte(j))) end
        out[#out + 1] = table.concat(o)
        counter = counter + 1
    end
    return table.concat(out)
end

local function keys(enc)
    return crypto.fromHex(enc:sub(1, 32)), enc:sub(33, 64)
end

function M.seal(enc, plain)
    local kb, mk = keys(enc)
    local nonce = crypto.randomBytes(8)
    local ct = ctr(kb, nonce, plain)
    local tag = crypto.hmacRaw(mk, nonce .. ct):sub(1, 16)
    return crypto.toHex(nonce .. ct .. tag)
end

function M.open(enc, hex)
    if type(hex) ~= "string" or #hex < 48 or #hex % 2 ~= 0 then return nil, "bad format" end
    local kb, mk = keys(enc)
    local raw = crypto.fromHex(hex)
    local nonce, tag, ct = raw:sub(1, 8), raw:sub(-16), raw:sub(9, -17)
    if crypto.hmacRaw(mk, nonce .. ct):sub(1, 16) ~= tag then return nil, "bad tag" end
    return ctr(kb, nonce, ct)
end

return M
