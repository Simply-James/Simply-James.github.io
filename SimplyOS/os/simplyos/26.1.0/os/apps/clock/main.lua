-- /os/apps/clock/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui
local timefmt = dofile("/os/lib/timefmt.lua")
local font = E.ctx.font

local tab = "clock"
local sw = { running = false, base = 0, start = 0 }
local tm = { secs = 60, running = false, left = 0, endAt = 0, done = false }
local lastShown = ""

local function bigText(g, str, y, color)
    local m = E.m
    local scale = math.max(1, math.min(6, math.floor((E.w - 2 * m.pad) / (8 * #str))))
    local w = font.width(str, "normal", scale)
    font.draw(E.cx - 1 + math.floor((E.w - w) / 2) + 1, E.cy - 1 + y, str, color, E.c.bg, "normal", scale)
    return font.height("normal", scale)
end

local function swElapsed() return sw.base + (sw.running and (os.clock() - sw.start) or 0) end
local function fmtSw(t)
    local m = math.floor(t / 60)
    return string.format("%02d:%02d.%d", m, math.floor(t % 60), math.floor((t * 10) % 10))
end
local function fmtTm(s) return string.format("%02d:%02d", math.floor(s / 60), s % 60) end

local scene = E.scene{}
local tabs = {}

local function mk(label, fn, style) return ui.button{ label = label, onTap = fn, style = style } end
for _, t in ipairs({ { "clock", "Clock" }, { "stopwatch", "Stopwatch" }, { "timer", "Timer" } }) do
    tabs[#tabs + 1] = { id = t[1], b = mk(t[2], function() tab = t[1]; scene.setTab() end) }
end

local swStart = mk("Start", function()
    if sw.running then sw.base = swElapsed(); sw.running = false else sw.start = os.clock(); sw.running = true end
    scene.setTab()
end, "primary")
local swReset = mk("Reset", function() sw.running = false; sw.base = 0; E.dirty() end)

local function tmAdjust(d)
    return function()
        if not tm.running then tm.secs = math.max(0, math.min(5999, tm.secs + d)); tm.left = 0; tm.done = false end
    end
end
local tmBtns = {
    mk("-1m", tmAdjust(-60)), mk("+1m", tmAdjust(60)), mk("-10s", tmAdjust(-10)), mk("+10s", tmAdjust(10)),
}
local tmStart = mk("Start", function()
    if tm.running then
        tm.left = math.max(0, math.ceil(tm.endAt - os.clock())); tm.running = false
    else
        local s = (tm.left > 0 and tm.left) or tm.secs
        if s > 0 then tm.left = s; tm.endAt = os.clock() + s; tm.running = true; tm.done = false end
    end
    scene.setTab()
end, "primary")
local tmReset = mk("Reset", function() tm.running = false; tm.left = 0; tm.done = false; scene.setTab() end)

function scene.setTab()
    local w = {}
    for _, t in ipairs(tabs) do w[#w + 1] = t.b end
    if tab == "stopwatch" then
        swStart.label = sw.running and "Stop" or "Start"
        w[#w + 1] = swStart; w[#w + 1] = swReset
    elseif tab == "timer" then
        tmStart.label = tm.running and "Pause" or "Start"
        for _, b in ipairs(tmBtns) do w[#w + 1] = b end
        w[#w + 1] = tmStart; w[#w + 1] = tmReset
    end
    scene.widgets = w
    E.dirty()
end
scene.setTab()

function scene:update(dt)
    if tab == "clock" then
        local h, m, s = timefmt.now()
        local key = timefmt.fmt(h, m, s)
        if key ~= lastShown then lastShown = key return true end
    elseif tab == "stopwatch" then
        return sw.running
    else
        if tm.running then
            if os.clock() >= tm.endAt then
                tm.running, tm.left, tm.done = false, 0, true
                E.notify{ title = "Timer", text = "Timer finished" }
                scene.setTab()
            end
            return true
        end
    end
    return false
end

function scene:drawUI(g)
    local m, c = E.m, E.c
    local tw = math.floor((E.w - 2 * m.pad - 8) / 3)
    for i, t in ipairs(tabs) do
        t.b:setRect(m.pad + (i - 1) * (tw + 4), m.pad, tw, m.target)
        t.b.style = (t.id == tab) and "primary" or "plain"
    end
    local y = m.pad * 2 + m.target + 10
    if tab == "clock" then
        local h, mn, s, date = timefmt.now()
        local hh = bigText(g, timefmt.fmt(h, mn, s), y + 10, c.text)
        g.textCentered(math.floor(E.w / 2), y + 10 + hh + 8, date, "body", c.muted, c.bg)
    elseif tab == "stopwatch" then
        local hh = bigText(g, fmtSw(swElapsed()), y + 10, c.text)
        local by = y + 10 + hh + m.pad * 2
        local bw = math.floor((E.w - 2 * m.pad - 8) / 2)
        swStart:setRect(m.pad, by, bw, m.target)
        swReset:setRect(m.pad + bw + 8, by, bw, m.target)
    else
        local left = tm.running and math.max(0, math.ceil(tm.endAt - os.clock())) or (tm.left > 0 and tm.left or tm.secs)
        local hh = bigText(g, fmtTm(left), y + 10, tm.done and 0xFFFF7070 or c.text)
        if tm.done then g.textCentered(math.floor(E.w / 2), y + 14 + hh, "Time is up", "body", 0xFFFF7070, c.bg) end
        local by = y + 10 + hh + m.pad * 2
        local bw = math.floor((E.w - 2 * m.pad - 12) / 4)
        for i, b in ipairs(tmBtns) do b:setRect(m.pad + (i - 1) * (bw + 4), by, bw, m.target) end
        local by2 = by + m.target + 8
        local hw = math.floor((E.w - 2 * m.pad - 8) / 2)
        tmStart:setRect(m.pad, by2, hw, m.target)
        tmReset:setRect(m.pad + hw + 8, by2, hw, m.target)
    end
end

E.run{ id = "clock", start = scene }
