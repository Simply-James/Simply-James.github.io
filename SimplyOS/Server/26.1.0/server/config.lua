-- /server/config.lua
-- Defaults here, operator overrides in /server/data/config.lua (only changed keys are stored).
return function(S)
    local M = {}
    local PATH = "/server/data/config.lua"

    M.defaults = {
        ["server.hostname"] = "root",
        ["net.protocol"] = "simplyos",
        ["net.rateLimit"] = 20, -- requests per second per computer id
        ["net.allowAnonPing"] = false, -- true = ping/pong answered without a login
        ["auth.sessionHours"] = 24,
        ["auth.maxAttempts"] = 5, -- hello per minute per computer id
        ["auth.blockSeconds"] = 60,
        ["auth.challengeSeconds"] = 30,
        ["mail.ttlDays"] = 7,
        ["mail.maxPerBox"] = 100,
        ["mail.maxBytesPerBox"] = 64000,
        ["repo.baseUrl"] = "https://sj.madefor.cc/SimplyOS",
        ["repo.allowedHosts"] = {"sj.madefor.cc"}, -- hosts the server itself may fetch from
        ["repo.maxBody"] = 500000, -- largest single file the server will download
        ["repo.timeout"] = 20,
        ["net.requireEncryption"] = true, -- message bodies must be sealed with the session key
        ["push.autoUpdates"] = true, -- broadcast a notification when an update is enabled
        ["push.keepDays"] = 14,
        ["backup.localMinutes"] = 30, -- local copy on the storage disks, written when something changed
        ["backup.warnDays"] = 7, -- Status warns when the last floppy backup is older
        ["admin.remote"] = true, -- admin phones may use admin.* packets
        ["log.maxFiles"] = 3,
        ["log.maxBytes"] = 32000,
        ["phone.numberFormat"] = "NNN-NNNN",
        ["store.reserve"] = 50000, -- free space kept back on the main disk
        ["storage.reserve"] = 2000, -- free space kept back on each Storage_ disk
        ["storage.fallback"] = true, -- use the main disk when no Storage_ disk has room
        ["storage.scanSeconds"] = 30,
        ["mail.sweepMinutes"] = 10,
        ["wdt.enabled"] = false, -- feed a tm_wdt watchdog if attached
        ["wdt.feedSeconds"] = 5
    }

    local over = {}

    function M.load()
        local raw = S.store.read(PATH, {})
        over = {}
        for k, v in pairs(raw) do
            local d = M.defaults[k]
            if d ~= nil and type(d) == type(v) then over[k] = v end
        end
    end

    function M.get(key)
        local v = over[key]
        if v ~= nil then return v end
        return M.defaults[key]
    end

    function M.set(key, value)
        local d = M.defaults[key]
        if d == nil then return false, "unknown key" end
        if type(d) ~= type(value) then
            return false, "expected " .. type(d)
        end
        over[key] = value
        local ok, why = S.store.write(PATH, over, true)
        if S.backup then S.backup.touch() end
        return ok, why
    end

    function M.exportOverrides() return over end

    function M.importOverrides(t)
        over = {}
        for k, v in pairs(t or {}) do
            local d = M.defaults[k]
            if d ~= nil and type(d) == type(v) then over[k] = v end
        end
        S.store.write(PATH, over, true)
    end

    function M.reset(key)
        over[key] = nil
        return S.store.write(PATH, over, true)
    end

    function M.keys()
        local list = {}
        for k in pairs(M.defaults) do list[#list + 1] = k end
        table.sort(list)
        return list
    end

    return M
end
