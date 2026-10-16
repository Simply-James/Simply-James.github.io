-- /os/engine/input.lua
-- Turns tm_monitor_touch (taps and ~200 ms repeats) into touch, drag, hold, release.
local I = {}
local GAP = 0.35

function I.new(emit)
    local s = { down = false, lastT = 0, startT = 0, lx = 0, ly = 0 }

    function s.feed(ev, now)
        local x, y
        for i = ev.n or #ev, 2, -1 do
            if type(ev[i]) == "number" then
                if not y then y = ev[i] elseif not x then x = ev[i] break end
            end
        end
        if not x or not y then return end
        x, y = math.floor(x), math.floor(y)
        if not s.down or now - s.lastT > GAP then
            if s.down then emit("release", s.lx, s.ly) end
            s.down, s.startT = true, now
            emit("touch", x, y, ev[5] == true)
        else
            if math.abs(x - s.lx) > 2 or math.abs(y - s.ly) > 2 then
                emit("drag", x, y, x - s.lx, y - s.ly)
            else
                emit("hold", x, y, now - s.startT)
            end
        end
        s.lx, s.ly, s.lastT = x, y, now
    end

    function s.tick(now)
        if s.down and now - s.lastT > GAP then
            s.down = false
            emit("release", s.lx, s.ly)
        end
    end

    function s.reset() s.down = false end
    return s
end

return I
