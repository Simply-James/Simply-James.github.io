-- /os/engine/init.lua
-- Game Engine entry. local E = dofile("/os/engine/init.lua")  then  E.run{id=..., start=scene}
local ctx = _G.SimplyOS
if not ctx then error("SimplyOS is not running", 0) end

local fsutil = dofile("/os/lib/fsutil.lua")
local settings = ctx.settings
local theme = ctx.theme
local display = ctx.display
local font = ctx.font
local appslib = dofile("/os/lib/apps.lua")
local gfxmod = dofile("/os/engine/gfx.lua")
local inputmod = dofile("/os/engine/input.lua")
local atlasmod = dofile("/os/engine/atlas.lua")

local E = { ctx = ctx, version = "26.1.0" }
E.g = gfxmod.new(ctx)
E.w, E.h, E.cx, E.cy = display.w(), display.h(), 1, 1
E.c = theme.colors()
E.m = theme.metrics()

local stack = {}
local running = false
local isDirty = true
local tweens = {}
local captured = nil
local frameTimer
local lastFrame = os.clock()
local fps, frameMs, fpsAcc, fpsN, fpsT = 0, 0, 0, 0, os.clock()
local vram = ""
local loadedAtlases = {}
local app = {}

function E.dirty() isDirty = true end

function E.refresh()
    local L = ctx.layout or { cx = 1, cy = 1, cw = display.w(), ch = display.h() }
    E.cx, E.cy, E.w, E.h = L.cx, L.cy, L.cw, L.ch
    E.pw, E.ph = display.pw, display.ph
    E.c = theme.colors()
    E.m = theme.metrics()
    E.level = settings.get("display.textLevel")
    E.g.setView(E.cx, E.cy, E.w, E.h)
    E.g.c = E.c
    E.g.level = E.level
    isDirty = true
end

function E.contentRect() return E.cx, E.cy, E.w, E.h end

-- ---------------------------------------------------------------- scenes
local function noop() end
local defaults = {
    load = noop, update = noop, drawBack = noop, drawUI = noop, touch = noop, drag = noop, hold = noop,
    release = noop, pause = noop, resume = noop, exit = noop, resize = noop, event = noop,
}
local meta = { __index = defaults }

function E.scene(t)
    t = t or {}
    return setmetatable(t, meta)
end

local function top() return stack[#stack] end

function E.push(s)
    local below = top()
    if below then below:pause() end
    stack[#stack + 1] = s
    captured = nil
    s:load()
    isDirty = true
end

function E.pop()
    local s = table.remove(stack)
    if s then s:exit() end
    captured = nil
    local t = top()
    if t then t:resume() else running = false end
    isDirty = true
end

function E.switch(s)
    local old = table.remove(stack)
    if old then old:exit() end
    stack[#stack + 1] = s
    captured = nil
    s:load()
    isDirty = true
end

function E.quit() running = false end

-- ---------------------------------------------------------------- tweens
local ease = {
    linear = function(t) return t end,
    out = function(t) return 1 - (1 - t) * (1 - t) end,
    inout = function(t) return t < 0.5 and 2 * t * t or 1 - 2 * (1 - t) * (1 - t) end,
}

function E.tween(obj, props, seconds, easing)
    local from = {}
    for k in pairs(props) do from[k] = obj[k] end
    tweens[#tweens + 1] = { obj = obj, from = from, to = props, t = 0, dur = math.max(0.001, seconds or 0.3),
        ease = ease[easing or "linear"] or ease.linear }
end

local function updateTweens(dt)
    local i = 1
    while i <= #tweens do
        local tw = tweens[i]
        tw.t = tw.t + dt
        local f = math.min(1, tw.t / tw.dur)
        local e = tw.ease(f)
        for k, to in pairs(tw.to) do tw.obj[k] = tw.from[k] + (to - tw.from[k]) * e end
        if f >= 1 then table.remove(tweens, i) else i = i + 1 end
    end
    if #tweens > 0 then isDirty = true end
end

-- ---------------------------------------------------------------- services for apps
E.settings = {
    get = function(key, default) return settings.get(key, default) end,
    set = function(key, value)
        local own = "app." .. tostring(app.id) .. "."
        if app.system or key:sub(1, #own) == own then return settings.set(key, value) end
        return false, "not allowed"
    end,
}

function E.notify(o)
    ctx.notify{ appId = app.id, title = o.title, text = o.text }
end

function E.toast(text) os.queueEvent("simplyos_toast", tostring(text)) end

function E.sim()
    local sim = dofile("/os/lib/sim.lua").read()
    return { number = sim and sim.number or nil }
end

function E.log(text)
    if settings.get("dev.logging") then pcall(fsutil.log, app.id or "engine", text) end
end

E.text = { level = function(n) return font.level(n) end }
E.device = {
    orientation = function() return ctx.rot or 0 end,
    landscape = function() return (ctx.rot == 1 or ctx.rot == 3) end,
}
E.net = dofile("/os/engine/net.lua")
E.ui = dofile("/os/engine/ui.lua")(E)

E.atlas = {
    load = function(path)
        local a, err = atlasmod.load(ctx, path)
        if a then loadedAtlases[#loadedAtlases + 1] = a end
        return a, err
    end,
    unload = function(a) atlasmod.unload(a) end,
    uv = atlasmod.uv,
}

-- ---------------------------------------------------------------- drawing
local function drawFrame()
    local s = top()
    if not s then return end
    local g = E.g
    g.clear(E.c.bg)
    s:drawBack(g)
    if s.draw3d then
        E.g3 = E.g3 or dofile("/os/engine/gfx3d.lua").new(ctx)
        s:draw3d(E.g3)
        E.g3.flush()
        if ctx.chromeDraw then pcall(ctx.chromeDraw) end
    end
    s:drawUI(g)
    for _, w in ipairs(s.widgets or {}) do
        if w.visible ~= false and w.draw then w:draw(g) end
    end
    if E.debugOn then
        local txt = string.format("%d fps %.0f ms %s", fps, frameMs, vram)
        g.text(E.w - g.textWidth(txt, 1) - 2, 2, txt, 1, 0xFFFFD84A, 0xFF000000)
    end
    display.sync()
    isDirty = false
end

function E.drawNow() if not (ctx.blank or ctx.overlay) then drawFrame() end end

-- ---------------------------------------------------------------- input
local input
local function emit(kind, a, b, c2, d)
    local s = top()
    if not s then return end
    local widgets = s.widgets or {}
    if kind == "touch" then
        captured = nil
        for i = #widgets, 1, -1 do
            local w = widgets[i]
            if w.touch and w.visible ~= false and w:touch(a, b) then captured = w break end
        end
        if not captured then s:touch(a, b, c2) end
    elseif kind == "drag" then
        if captured then if captured.drag then captured:drag(a, b, c2, d) end else s:drag(a, b, c2, d) end
    elseif kind == "hold" then
        if captured then if captured.hold then captured:hold(a, b, c2) end else s:hold(a, b, c2) end
    elseif kind == "release" then
        if captured then if captured.release then captured:release(a, b) end else s:release(a, b) end
        captured = nil
    end
    isDirty = true
end

-- ---------------------------------------------------------------- error page
local function errorPage(err)
    local g = E.g
    g.clear(0xFF300000)
    g.text(4, 4, "App error", "title", 0xFFFFFFFF, 0xFF300000)
    local y = 8 + g.lineHeight("title")
    for _, ln in ipairs(g.wrap(tostring(err), E.w - 8, 1)) do
        if y + g.lineHeight(1) > E.h then break end
        g.text(4, y, ln, 1, 0xFFFFD0D0, 0xFF300000)
        y = y + g.lineHeight(1)
    end
    display.sync()
    while true do
        local ev = os.pullEvent()
        if ev == "simplyos_back" or ev == "simplyos_exit" or ev == "tm_monitor_touch" then return end
    end
end

-- ---------------------------------------------------------------- run loop
local function handle(ev)
    local name = ev[1]
    local now = os.clock()
    if name == "timer" then
        if ev[2] == frameTimer then
            frameTimer = os.startTimer(0.05)
            local dt = math.min(0.1, now - lastFrame)
            lastFrame = now
            input.tick(now)
            updateTweens(dt)
            local s = top()
            if s then
                if s:update(dt) then isDirty = true end
                if s.continuous then isDirty = true end
            end
            if ctx.blank or ctx.overlay then return end
            if isDirty then
                local t0 = os.clock()
                drawFrame()
                frameMs = (os.clock() - t0) * 1000
                fpsAcc = fpsAcc + 1
                if now - fpsT >= 1 then
                    fps, fpsAcc, fpsT = fpsAcc, 0, now
                    if E.debugOn then
                        local ok, u, m = pcall(function() return display.gpu.getUsedMemory(), display.gpu.getMaxMemory() end)
                        if ok and u then vram = string.format("%.1f/%.0fMB", u / 1048576, m / 1048576) end
                    end
                end
            end
            if app.store then app.store.flush() end
        else
            local s = top()
            if s then s:event(ev) end
        end
    elseif name == "tm_monitor_touch" then
        if not (ctx.blank or ctx.overlay) then input.feed(ev, now) end
    elseif name == "simplyos_back" then
        local s = top()
        if s and s.back and s:back() then isDirty = true
        else E.pop() end
    elseif name == "simplyos_exit" then
        running = false
    elseif name == "simplyos_relayout" then
        E.refresh()
        for _, s in ipairs(stack) do s:resize() end
        input.reset()
    elseif name == "simplyos_redraw" then
        E.refresh()
        isDirty = true
    else
        local s = top()
        if s then s:event(ev) end
    end
end

function E.run(opts)
    app.id = opts.id or "app"
    local info = appslib.find(app.id)
    app.system = info and info.system or false
    app.name = info and info.name or app.id
    E.appId = app.id
    E.store = dofile("/os/engine/store.lua").new(app.id)
    app.store = E.store
    E.debugOn = settings.get("dev.fpsOverlay")
    E.refresh()
    input = inputmod.new(emit)
    running = true
    stack = {}
    local ok, err = pcall(function()
        E.push(opts.start)
        frameTimer = os.startTimer(0.05)
        lastFrame = os.clock()
        while running do
            handle(table.pack(os.pullEvent()))
        end
    end)
    for i = #stack, 1, -1 do pcall(stack[i].exit, stack[i]) end
    stack = {}
    for _, a in ipairs(loadedAtlases) do pcall(atlasmod.unload, a) end
    pcall(E.store.flush, true)
    if not ok then
        pcall(fsutil.log, app.id, tostring(err))
        if settings.get("dev.enabled") then
            pcall(errorPage, err)
        else
            error(err, 0)
        end
    end
end

return E
