-- /os/lib/timefmt.lua
local settings = dofile("/os/lib/settings.lua")
local M = {}

-- returns hour, minute, second, and a date string
function M.now()
    if settings.get("clock.source") == "ingame" then
        local t = os.time()
        local h = math.floor(t)
        local m = math.floor((t - h) * 60)
        return h % 24, m, 0, "Day " .. os.day()
    end
    local d = os.date("*t", math.floor(os.epoch("local") / 1000))
    return d.hour, d.min, d.sec, os.date("%a %b %d", math.floor(os.epoch("local") / 1000))
end

function M.fmt(h, m, s)
    local suffix = ""
    if settings.get("clock.format") == "12" then
        suffix = h >= 12 and " PM" or " AM"
        h = h % 12
        if h == 0 then h = 12 end
        if s then return string.format("%d:%02d:%02d%s", h, m, s, suffix) end
        return string.format("%d:%02d%s", h, m, suffix)
    end
    if s then return string.format("%02d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", h, m)
end

return M
