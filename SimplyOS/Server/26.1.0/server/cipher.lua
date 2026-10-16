-- /server/cipher.lua
-- AES-128-CTR plus HMAC-SHA256 tag (encrypt then MAC), pure Lua. The accelerator's encryptAes
-- arguments are untested, so it is not used here.
--   seal(keyHex, plain)  -> hex string  = hex(nonce8 .. ciphertext .. tag16)
--   open(keyHex, hex)    -> plain, or nil if the tag does not match
-- keyHex is 64 hex chars: first 32 = AES key (16 bytes), last 32 = MAC key (used as ASCII text).
-- Needs S.crypto.hmac(key, msg) -> hex and S.crypto.random(n) -> hex. The phone uses the same code.
return function(S)
    local M = {}
    local band, bxor, bor, lshift, rshift = bit32.band, bit32.bxor, bit32.bor,
                                            bit32.lshift, bit32.rshift

    local sbox = {}
    do
        local function rotl(x, n)
            return band(bor(lshift(x, n), rshift(x, 8 - n)), 255)
        end
        local p, q = 1, 1
        repeat
            p = band(bxor(p, lshift(p, 1), band(p, 0x80) ~= 0 and 0x1B or 0),
                     255)
            q = band(bxor(q, lshift(q, 1)), 255)
            q = band(bxor(q, lshift(q, 2)), 255)
            q = band(bxor(q, lshift(q, 4)), 255)
            if band(q, 0x80) ~= 0 then q = bxor(q, 0x09) end
            sbox[p] = bxor(q, rotl(q, 1), rotl(q, 2), rotl(q, 3), rotl(q, 4),
                           0x63)
        until p == 1
        sbox[0] = 0x63
    end

    local rcon = {1, 2, 4, 8, 16, 32, 64, 128, 27, 54}

    local function expand(key)
        local w = {}
        for i = 1, 16 do w[i] = key[i] end
        for i = 17, 176, 4 do
            local a, b, c, d = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
            if (i - 1) % 16 == 0 then
                a, b, c, d = sbox[b], sbox[c], sbox[d], sbox[a]
                a = bxor(a, rcon[(i - 1) / 16])
            end
            w[i] = bxor(w[i - 16], a)
            w[i + 1] = bxor(w[i - 15], b)
            w[i + 2] = bxor(w[i - 14], c)
            w[i + 3] = bxor(w[i - 13], d)
        end
        return w
    end

    local function xt(a)
        a = lshift(a, 1)
        if a > 255 then a = bxor(a, 0x11B) end
        return a
    end

    local function encryptBlock(inp, w)
        local s, t = {}, {}
        for i = 1, 16 do s[i] = bxor(inp[i], w[i]) end
        for round = 1, 10 do
            t[1], t[5], t[9], t[13] = sbox[s[1]], sbox[s[5]], sbox[s[9]],
                                      sbox[s[13]]
            t[2], t[6], t[10], t[14] = sbox[s[6]], sbox[s[10]], sbox[s[14]],
                                       sbox[s[2]]
            t[3], t[7], t[11], t[15] = sbox[s[11]], sbox[s[15]], sbox[s[3]],
                                       sbox[s[7]]
            t[4], t[8], t[12], t[16] = sbox[s[16]], sbox[s[4]], sbox[s[8]],
                                       sbox[s[12]]
            local base = round * 16
            if round < 10 then
                for c = 0, 12, 4 do
                    local a0, a1, a2, a3 = t[c + 1], t[c + 2], t[c + 3],
                                           t[c + 4]
                    local x0, x1, x2, x3 = xt(a0), xt(a1), xt(a2), xt(a3)
                    s[c + 1] = bxor(x0, x1, a1, a2, a3, w[base + c + 1])
                    s[c + 2] = bxor(a0, x1, x2, a2, a3, w[base + c + 2])
                    s[c + 3] = bxor(a0, a1, x2, x3, a3, w[base + c + 3])
                    s[c + 4] = bxor(x0, a0, a1, a2, x3, w[base + c + 4])
                end
            else
                for i = 1, 16 do s[i] = bxor(t[i], w[base + i]) end
            end
        end
        return s
    end
    M.encryptBlock = function(keyBytes, block)
        return encryptBlock(block, expand(keyBytes))
    end

    local function tohex(s)
        return (s:gsub(".",
                       function(c) return string.format("%02x", c:byte()) end))
    end
    local function fromhex(h)
        return (h:gsub("%x%x",
                       function(x) return string.char(tonumber(x, 16)) end))
    end

    local function ctr(w, nonce, data)
        local out, ctrBlock = {}, {}
        for i = 1, 8 do ctrBlock[i] = nonce:byte(i) end
        for blk = 0, math.ceil(#data / 16) - 1 do
            ctrBlock[9], ctrBlock[10], ctrBlock[11], ctrBlock[12] = 0, 0, 0, 0
            ctrBlock[13] = band(rshift(blk, 24), 255)
            ctrBlock[14] = band(rshift(blk, 16), 255)
            ctrBlock[15] = band(rshift(blk, 8), 255)
            ctrBlock[16] = band(blk, 255)
            local ks = encryptBlock(ctrBlock, w)
            for j = 1, 16 do
                local pos = blk * 16 + j
                if pos > #data then break end
                out[pos] = string.char(bxor(data:byte(pos), ks[j]))
            end
        end
        return table.concat(out)
    end

    local function keyParts(keyHex)
        local k = {}
        local raw = fromhex(keyHex:sub(1, 32))
        for i = 1, 16 do k[i] = raw:byte(i) end
        return expand(k), keyHex:sub(33, 64)
    end

    function M.seal(keyHex, plain)
        local w, macKey = keyParts(keyHex)
        local nonce = fromhex(S.crypto.random(8))
        local ct = ctr(w, nonce, plain)
        local tag = S.crypto.hmac(macKey, nonce .. ct):sub(1, 32)
        return tohex(nonce .. ct) .. tag
    end

    function M.open(keyHex, hex)
        if type(keyHex) ~= "string" or #keyHex ~= 64 then return nil end
        if type(hex) ~= "string" or #hex < 48 or #hex % 2 ~= 0 or
            hex:match("%X") then return nil end
        local w, macKey = keyParts(keyHex)
        local body = fromhex(hex:sub(1, #hex - 32))
        local tag = hex:sub(#hex - 31):lower()
        local nonce, ct = body:sub(1, 8), body:sub(9)
        if not S.crypto
            .equal(S.crypto.hmac(macKey, nonce .. ct):sub(1, 32), tag) then
            return nil
        end
        return ctr(w, nonce, ct)
    end

    return M
end
