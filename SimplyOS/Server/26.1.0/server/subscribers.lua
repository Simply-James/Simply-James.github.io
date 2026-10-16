-- /server/subscribers.lua
-- Subscriber records and the master secret. Both live on the main disk, written with force.
-- key = hmac(master, number .. ":" .. imsi), so no per-phone secret is stored.
return function(S)
    local M = {secretBad = false}
    local PATH = "/server/data/subscribers.lua"
    local SECRET = "/server/data/secret.lua"
    local subs, master, dirty = {}, nil, false

    function M.valid(number)
        return
            type(number) == "string" and number:match("^%d%d%d%-%d%d%d%d$") ~=
                nil
    end

    function M.load()
        subs = S.store.read(PATH, {})
        local sec = S.store.read(SECRET, nil)
        if sec and type(sec.master) == "string" and #sec.master == 64 then
            master = sec.master
        elseif S.store.exists(SECRET) then
            -- never regenerate: that would invalidate every SIM
            M.secretBad = true
            S.log.error("subscribers",
                        "secret.lua exists but is unreadable; logins disabled")
        else
            master = S.crypto.random(32)
            S.store.write(SECRET, {master = master}, true)
            S.log.info("subscribers", "created new master secret")
        end
    end

    function M.deriveKey(number, imsi)
        return S.crypto.hmac(master, number .. ":" .. imsi)
    end

    function M.key(number)
        local r = subs[number]
        if not r or not master then return nil end
        return M.deriveKey(number, r.imsi)
    end

    function M.get(number) return subs[number] end

    function M.save()
        local ok = S.store.write(PATH, subs, true)
        dirty = not ok
        if S.backup then S.backup.touch() end
        return ok
    end

    -- key for encrypting stored message bodies (derived, never stored)
    function M.storageKey()
        return master and S.crypto.hmac(master, "storage") or nil
    end

    -- for backup / restore
    function M.exportAll() return {master = master, subs = subs} end

    function M.importAll(newMaster, newSubs)
        S.store.write(SECRET, {master = newMaster}, true)
        S.store.write(PATH, newSubs, true)
        master, subs, M.secretBad = newMaster, newSubs, false
    end

    function M.list()
        local out = {}
        for n, r in pairs(subs) do out[#out + 1] = {number = n, rec = r} end
        table.sort(out, function(a, b) return a.number < b.number end)
        return out
    end

    function M.count()
        local c = 0
        for _ in pairs(subs) do c = c + 1 end
        return c
    end

    function M.newNumber()
        for _ = 1, 2000 do
            local n = string.format("%03d-%04d", math.random(100, 999),
                                    math.random(0, 9999))
            if not subs[n] then return n end
        end
    end

    function M.newImsi()
        local hex = S.crypto.random(15)
        local out = {}
        for i = 1, 15 do
            out[i] = tostring(tonumber(hex:sub(i * 2 - 1, i * 2), 16) % 10)
        end
        return table.concat(out)
    end

    function M.create(number, imsi, note, admin)
        if subs[number] then return false, "exists" end
        subs[number] = {
            imsi = imsi,
            status = "active",
            issued = S.util.now(),
            note = note or "",
            lastSeen = 0,
            admin = admin and true or false,
            pushSeen = S.push and S.push.latest() or 0
        }
        if not M.save() then
            subs[number] = nil
            return false, "save failed"
        end
        return true
    end

    function M.setStatus(number, status)
        local r = subs[number]
        if not r then return false end
        r.status = status
        if status ~= "active" and S.auth then S.auth.kick(number) end
        return M.save()
    end

    function M.setAdmin(number, value)
        local r = subs[number]
        if not r then return false end
        r.admin = value and true or false
        return M.save()
    end

    function M.isAdmin(number)
        local r = subs[number]
        return r ~= nil and r.admin == true and r.status == "active"
    end

    function M.setPushSeen(number, id)
        local r = subs[number]
        if r and (r.pushSeen or 0) < id then
            r.pushSeen = id;
            dirty = true
        end
    end

    function M.setNote(number, note)
        local r = subs[number]
        if not r then return false end
        r.note = note
        return M.save()
    end

    function M.remove(number)
        if not subs[number] then return false end
        subs[number] = nil
        if S.auth then S.auth.kick(number) end
        return M.save()
    end

    -- lastSeen is kept in memory and flushed by the housekeeping task
    function M.touch(number)
        local r = subs[number]
        if r then
            r.lastSeen = S.util.now();
            dirty = true
        end
    end

    function M.flush() if dirty then M.save() end end

    return M
end
