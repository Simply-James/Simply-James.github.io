-- /server/crypto.lua
-- Wrapper over the cryptographic accelerator. Nothing else in the server calls the peripheral.
-- Conventions (keep the phone side identical):
--   sha256(str)            -> 64 char lowercase hex
--   hmac(key, msg)         -> 64 char lowercase hex. key and msg are used as plain strings,
--                             so a hex key is the ASCII text of the hex, not decoded bytes.
--   random(nbytes)         -> hex string of 2*nbytes chars
-- Argument order and output format of the accelerator are untested, so init() checks every
-- method against known test vectors and picks the working variant. Anything that fails the
-- check, or throws later, falls back to the pure Lua implementation (slow, fine at this scale).
return function(S)
    local M = {
        mode = "pure",
        info = {},
        hmacOrder = nil,
        hwSha = false,
        hwShaBinary = false,
        hwRandom = false
    }

    local band, bxor, bnot, rshift, rrot = bit32.band, bit32.bxor, bit32.bnot,
                                           bit32.rshift, bit32.rrotate

    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    }

    local function u32be(n)
        return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255),
                           band(rshift(n, 8), 255), band(n, 255))
    end

    local function tohex(s)
        return (s:gsub(".",
                       function(c) return string.format("%02x", c:byte()) end))
    end

    local function fromhex(h)
        return (h:gsub("%x%x",
                       function(x) return string.char(tonumber(x, 16)) end))
    end

    local function sha256bin(msg)
        local len = #msg
        local bits = len * 8
        msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) ..
                  u32be(math.floor(bits / 4294967296)) ..
                  u32be(bits % 4294967296)
        local H = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f,
            0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        }
        local w = {}
        for i = 1, #msg, 64 do
            if i > 1 and (i - 1) % 12800 == 0 then
                os.queueEvent("sha_yield");
                os.pullEvent("sha_yield")
            end
            for j = 0, 15 do
                local a, b, c, d = msg:byte(i + j * 4, i + j * 4 + 3)
                w[j + 1] = ((a * 256 + b) * 256 + c) * 256 + d
            end
            for j = 17, 64 do
                local x, y = w[j - 15], w[j - 2]
                local s0 = bxor(rrot(x, 7), rrot(x, 18), rshift(x, 3))
                local s1 = bxor(rrot(y, 17), rrot(y, 19), rshift(y, 10))
                w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % 4294967296
            end
            local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6],
                                           H[7], H[8]
            for j = 1, 64 do
                local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local t1 = (h + S1 + ch + K[j] + w[j]) % 4294967296
                local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
                local maj = bxor(band(a, b), band(a, c), band(b, c))
                local t2 = (S0 + maj) % 4294967296
                h = g;
                g = f;
                f = e
                e = (d + t1) % 4294967296
                d = c;
                c = b;
                b = a
                a = (t1 + t2) % 4294967296
            end
            H[1] = (H[1] + a) % 4294967296;
            H[2] = (H[2] + b) % 4294967296
            H[3] = (H[3] + c) % 4294967296;
            H[4] = (H[4] + d) % 4294967296
            H[5] = (H[5] + e) % 4294967296;
            H[6] = (H[6] + f) % 4294967296
            H[7] = (H[7] + g) % 4294967296;
            H[8] = (H[8] + h) % 4294967296
        end
        return u32be(H[1]) .. u32be(H[2]) .. u32be(H[3]) .. u32be(H[4]) ..
                   u32be(H[5]) .. u32be(H[6]) .. u32be(H[7]) .. u32be(H[8])
    end

    local function hmacbin(key, msg, shaf)
        shaf = shaf or sha256bin
        if #key > 64 then key = shaf(key) end
        key = key .. string.rep("\0", 64 - #key)
        local ip, op = {}, {}
        for i = 1, 64 do
            local k = key:byte(i)
            ip[i] = string.char(bxor(k, 0x36))
            op[i] = string.char(bxor(k, 0x5c))
        end
        return shaf(table.concat(op) .. shaf(table.concat(ip) .. msg))
    end

    -- hardware output (hex string, raw bytes or a table of bytes) -> lowercase hex of n bytes, or nil
    local function norm(v, n)
        if type(v) == "string" then
            if #v == n then return tohex(v) end
            if #v == 2 * n and v:match("^%x+$") then return v:lower() end
        elseif type(v) == "table" and #v == n then
            local t = {}
            for i = 1, n do
                if type(v[i]) ~= "number" then return nil end
                t[i] = string.char(v[i] % 256)
            end
            return tohex(table.concat(t))
        end
        return nil
    end

    local V_SHA =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" -- sha256("abc")
    local V_HMAC =
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" -- RFC 4231 case 2
    local V_KEY, V_MSG = "Jefe", "what do ya want for nothing?"

    local function note(text) if S.log then S.log.info("crypto", text) end end

    -- pure Lua, always available
    function M.pureSha256(s) return tohex(sha256bin(s)) end
    function M.pureHmac(k, m) return tohex(hmacbin(k, m)) end

    function M.init()
        M.mode, M.info, M.hmacOrder, M.hwSha, M.hwShaBinary, M.hwRandom, M.hw =
            "pure", {}, nil, false, false, false, nil
        math.randomseed(os.epoch("utc"))

        if M.pureSha256("abc") ~= V_SHA or M.pureHmac(V_KEY, V_MSG) ~= V_HMAC then
            M.info.pure = "BAD"
            if S.log then
                S.log.error("crypto", "pure Lua self-test FAILED")
            end
        else
            M.info.pure = "ok"
        end

        local hw = peripheral.find("cryptographic_accelerator")
        if not hw then
            M.info.hw = "not attached"
            note("no accelerator, using pure Lua")
            return M
        end
        M.hw = hw

        local ok, v = pcall(hw.sha256, "abc")
        if ok and norm(v, 32) == V_SHA then
            M.hwSha = true
            M.info.sha256 = "ok"
        else
            M.info.sha256 = "failed (" .. type(v) .. ")"
        end

        for _, order in ipairs({"km", "mk"}) do
            local a, b = V_KEY, V_MSG
            if order == "mk" then a, b = V_MSG, V_KEY end
            local ok2, v2 = pcall(hw.hmacSha256, a, b)
            if ok2 and norm(v2, 32) == V_HMAC then
                M.hmacOrder = order
                break
            end
        end
        -- Measured: the accelerator's hmacSha256 does not return standard HMAC. If sha256 handles
        -- binary strings (all 256 byte values) exactly like the pure Lua version, build HMAC from it.
        if M.hwSha then
            local all = {}
            for i = 0, 255 do all[#all + 1] = string.char(i) end
            all = table.concat(all)
            local okb, vb = pcall(M.hw.sha256, all)
            M.hwShaBinary = okb and norm(vb, 32) == M.pureSha256(all)
        end
        if M.hmacOrder then
            M.info.hmac = "ok, order " .. M.hmacOrder
        elseif M.hwShaBinary then
            M.info.hmac = "built from accelerator sha256"
        else
            M.info.hmac = "pure Lua (accelerator hmac not standard)"
        end

        local ok3, v3 = pcall(hw.randomBytes, 16)
        M.hwRandom = ok3 and norm(v3, 16) ~= nil
        M.info.random = M.hwRandom and "ok" or "failed"

        if M.hwSha or M.hmacOrder or M.hwRandom then M.mode = "hardware" end
        if M.hmacOrder == nil and not M.hwShaBinary then
            M.info.hmacPure = true
        end
        note(
            "accelerator: sha256 " .. M.info.sha256 .. ", hmac " .. M.info.hmac ..
                ", random " .. M.info.random)
        return M
    end

    function M.sha256(s)
        s = tostring(s)
        if M.hwSha then
            local ok, v = pcall(M.hw.sha256, s)
            local h = ok and norm(v, 32)
            if h then return h end
        end
        return M.pureSha256(s)
    end

    function M.hmac(key, msg)
        key, msg = tostring(key), tostring(msg)
        if M.hmacOrder then
            local a, b = key, msg
            if M.hmacOrder == "mk" then a, b = msg, key end
            local ok, v = pcall(M.hw.hmacSha256, a, b)
            local h = ok and norm(v, 32)
            if h then return h end
        end
        if M.hwShaBinary then
            local function hwsha(x)
                local ok, v = pcall(M.hw.sha256, x)
                local h = ok and norm(v, 32)
                if not h then error("accelerator sha256 failed") end
                return fromhex(h)
            end
            local ok, r = pcall(hmacbin, key, msg, hwsha)
            if ok and r then return tohex(r) end
        end
        return M.pureHmac(key, msg)
    end

    local counter = 0
    function M.random(n)
        n = n or 16
        if M.hwRandom then
            local ok, v = pcall(M.hw.randomBytes, n)
            local h = ok and norm(v, n)
            if h then return h end
        end
        -- fallback: hash of time, clock, math.random and a counter
        local out = ""
        while #out < n * 2 do
            counter = counter + 1
            out = out .. M.pureSha256(
                      os.epoch("utc") .. ":" .. os.clock() .. ":" ..
                          math.random() .. ":" .. counter)
        end
        return out:sub(1, n * 2)
    end

    -- constant time string compare
    function M.equal(a, b)
        if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
            return false
        end
        local acc = 0
        for i = 1, #a do acc = bit32.bor(acc, bxor(a:byte(i), b:byte(i))) end
        return acc == 0
    end

    function M.describe()
        if M.mode == "pure" then
            return "pure Lua (" .. tostring(M.info.hw or "no accelerator") ..
                       ")"
        end
        return "accelerator: sha256 " .. M.info.sha256 .. ", hmac " ..
                   M.info.hmac .. ", random " .. M.info.random
    end

    return M
end
