-- /server/util.lua
-- Small helpers. now() is real (UTC) seconds, used for every timestamp.
return function(S)
    local M = {}

    function M.now()
        return math.floor(os.epoch("utc") / 1000)
    end

    function M.stamp(t)
        return os.date("!%Y-%m-%d %H:%M:%S", t or M.now())
    end

    function M.bytes(n)
        n = n or 0
        if n >= 1000000 then return string.format("%.2f MB", n / 1000000) end
        if n >= 1000 then return string.format("%.1f KB", n / 1000) end
        return n .. " B"
    end

    function M.duration(s)
        s = math.floor(s or 0)
        local d = math.floor(s / 86400)
        local h = math.floor(s % 86400 / 3600)
        local m = math.floor(s % 3600 / 60)
        local sec = s % 60
        if d > 0 then return d .. "d " .. h .. "h " .. m .. "m" end
        if h > 0 then return h .. "h " .. m .. "m " .. sec .. "s" end
        if m > 0 then return m .. "m " .. sec .. "s" end
        return sec .. "s"
    end

    return M
end
