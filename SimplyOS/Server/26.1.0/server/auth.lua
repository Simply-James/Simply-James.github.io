-- /server/auth.lua
-- hello -> challenge -> auth -> session. Sessions are in memory only (lost on restart, phones
-- log in again). One session per number; a new login replaces the old one.
-- Every later packet carries tok and an increasing seq. A retry keeps its rid but uses a new seq.
return function(S)
    local M = {}
    local byTok, byNumber = {}, {}
    local pending, done, attempts = {}, {}, {}

    local function cfg(k) return S.config.get(k) end

    local function drop(s)
        byTok[s.tok] = nil
        if byNumber[s.number] == s then byNumber[s.number] = nil end
    end

    function M.kick(number)
        local s = byNumber[number]
        if s then drop(s) end
    end

    function M.sessionFor(number) return byNumber[number] end

    function M.list()
        local out = {}
        for _, s in pairs(byNumber) do out[#out + 1] = s end
        table.sort(out, function(a, b) return a.number < b.number end)
        return out
    end

    -- validates a session packet. returns session, or nil + error code
    function M.check(id, msg)
        local s = type(msg.tok) == "string" and byTok[msg.tok]
        if not s then return nil, "session" end
        local now = S.util.now()
        if s.expires <= now then
            drop(s)
            return nil, "session"
        end
        local rec = S.subscribers.get(s.number)
        if not rec or rec.status ~= "active" then
            drop(s)
            return nil, "auth"
        end
        if s.id ~= id then
            S.log.warn("auth",
                       "token of " .. s.number .. " used from computer " .. id)
            return nil, "session"
        end
        if type(msg.seq) ~= "number" or msg.seq <= s.seq then
            S.log.warn("auth",
                       "replayed or missing seq from " .. s.number .. " (seq " ..
                           tostring(msg.seq) .. ", last " .. s.seq .. ")")
            return nil, "session"
        end
        s.seq, s.last = msg.seq, now
        S.subscribers.touch(s.number)
        return s
    end

    local function limited(id, now)
        local a = attempts[id]
        if not a then
            a = {times = {}, blocked = 0};
            attempts[id] = a
        end
        if a.blocked > now then return true end
        local t = a.times
        t[#t + 1] = now
        while t[1] and now - t[1] >= 60 do table.remove(t, 1) end
        if #t > cfg("auth.maxAttempts") then
            a.blocked = now + cfg("auth.blockSeconds")
            a.times = {}
            S.log.warn("auth", "computer " .. id ..
                           " blocked for too many login attempts")
            return true
        end
        return false
    end

    S.net.on("hello", function(id, msg, d)
        local now = S.util.now()
        if limited(id, now) then
            S.net.err(id, msg, "busy", "too many attempts")
            return
        end
        if S.subscribers.secretBad then
            S.net.err(id, msg, "unknown", "server fault")
            return
        end
        local number, imsi = d.number, d.imsi
        local rec = type(number) == "string" and S.subscribers.get(number)
        if not rec or type(imsi) ~= "string" or rec.imsi ~= imsi or rec.status ~=
            "active" then
            S.log.warn("auth", "login refused: number " ..
                           tostring(number):sub(1, 12) .. " computer " .. id)
            S.net.err(id, msg, "auth", "denied")
            return
        end
        local nonce = S.crypto.random(16)
        pending[id] = {
            nonce = nonce,
            number = number,
            exp = now + cfg("auth.challengeSeconds")
        }
        S.net.send(id, "challenge", msg.rid, {nonce = nonce})
    end)

    S.net.on("auth", function(id, msg, d)
        local now = S.util.now()
        local mac = d.mac
        if type(mac) ~= "string" then
            S.net.err(id, msg, "auth", "denied")
            return
        end

        local p = pending[id]
        if not p then
            -- retry of an auth whose reply was lost
            local dn = done[id]
            if dn and dn.rid ~= nil and dn.rid == msg.rid and dn.mac == mac and
                dn.exp > now and byTok[dn.s.tok] then
                S.net.send(id, "session", msg.rid, {
                    tok = dn.s.tok,
                    expires = dn.s.expires,
                    serverTime = now,
                    admin = S.subscribers.isAdmin(dn.s.number),
                    enc = true
                })
            else
                S.net.err(id, msg, "auth", "no challenge")
            end
            return
        end
        pending[id] = nil
        if p.exp < now then
            S.net.err(id, msg, "auth", "challenge expired")
            return
        end

        local key = S.subscribers.key(p.number)
        local rec = S.subscribers.get(p.number)
        if not key or not rec or rec.status ~= "active" or
            not S.crypto
                .equal(S.crypto.hmac(key, p.nonce .. p.number), mac:lower()) then
            S.log.warn("auth",
                       "bad mac for " .. p.number .. " from computer " .. id)
            S.net.err(id, msg, "auth", "denied")
            return
        end

        M.kick(p.number)
        local s = {
            tok = S.crypto.random(16),
            number = p.number,
            id = id,
            expires = now + cfg("auth.sessionHours") * 3600,
            seq = 0,
            last = now,
            since = now,
            -- session encryption key (64 hex: 32 AES key + 32 MAC key); the phone derives the same
            enc = S.crypto.hmac(key, "enc|" .. p.nonce .. p.number)
        }
        byTok[s.tok], byNumber[s.number] = s, s
        done[id] = {rid = msg.rid, mac = mac, s = s, exp = now + 30}
        S.subscribers.touch(s.number)
        S.log.info("auth", "login " .. s.number .. " computer " .. id)
        S.net.send(id, "session", msg.rid, {
            tok = s.tok,
            expires = s.expires,
            serverTime = now,
            admin = S.subscribers.isAdmin(s.number),
            enc = true
        })
        if S.mail then S.mail.onLogin(s.number) end
        if S.push then S.push.onLogin(s.number) end
    end)

    function M.sweep()
        local now = S.util.now()
        for _, s in pairs(byTok) do if s.expires <= now then drop(s) end end
        for id, p in pairs(pending) do
            if p.exp < now then pending[id] = nil end
        end
        for id, dn in pairs(done) do
            if dn.exp < now then done[id] = nil end
        end
        for id, a in pairs(attempts) do
            if a.blocked < now and
                (#a.times == 0 or now - a.times[#a.times] > 120) then
                attempts[id] = nil
            end
        end
    end

    return M
end
