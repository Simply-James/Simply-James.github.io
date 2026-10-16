-- /os/kernel/boot.lua
-- Kernel entry: GPU, font, settings, boot screen, services, shell, scheduler loop.
-- run() returns "exit" (dev escape), "reboot" or "shutdown" to startup.lua.
local K = {}
local ENV = _ENV

local function lib(name) return dofile("/os/lib/" .. name .. ".lua") end

local function loadPng(gpu, path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local data = f.readAll()
    f.close()
    local buf = gpu.newBuffer(#data)
    for i = 1, #data, 2048 do
        buf.write(string.byte(data, i, math.min(i + 2047, #data)))
    end
    local img = gpu.decodeImage(buf.ref())
    buf.free()
    return img
end

local function toRGB(v)
    if v < 0 then v = v + 4294967296 end
    return math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256, math.floor(v / 16777216)
end

-- blend the logo onto the background in Lua (alpha blending of drawImage is untested)
local function compositeLogo(gpu, img, bg)
    local iw, ih = img.getWidth(), img.getHeight()
    local raw = { img.getAsBuffer() }
    if #raw ~= iw * ih then error("unexpected pixel count " .. #raw) end
    local signed = false
    for i = 1, #raw do
        if raw[i] < 0 then signed = true break end
    end
    local br, bgc, bb = toRGB(bg)
    local out = {}
    for i = 1, #raw do
        local r, g, b, a = toRGB(raw[i])
        local inv = 255 - a
        local px = 4278190080 + math.floor((r * a + br * inv) / 255) * 65536
            + math.floor((g * a + bgc * inv) / 255) * 256 + math.floor((b * a + bb * inv) / 255)
        if signed and px >= 2147483648 then px = px - 4294967296 end
        out[i] = px
    end
    local small = gpu.newImage(iw, ih)
    local ctx = small.gpuDraw()
    local rows = 4
    for y = 0, ih - 1, rows do
        local n = math.min(rows, ih - y)
        ctx.drawBuffer(1, y + 1, iw, 1, table.unpack(out, y * iw + 1, (y + n) * iw))
    end
    return small
end

local function bootScreen(ctx)
    local display, font = ctx.display, ctx.font
    local gpu = display.gpu
    local c = ctx.theme.colors()
    display.clear(c.bg)

    -- largest logo that is at most 50% of the short side; if none is that small, the smallest that fits
    local limit = math.floor(math.min(display.pw, display.ph) * 0.5)
    local sizes = { 256, 192, 128, 96 }
    local pick
    for _, s in ipairs(sizes) do
        local p = "/os/assets/logo_" .. s .. ".png"
        if s <= limit and fs.exists(p) then pick = p break end
    end
    if not pick then
        for i = #sizes, 1, -1 do
            local p = "/os/assets/logo_" .. sizes[i] .. ".png"
            if sizes[i] <= math.min(display.pw, display.ph) and fs.exists(p) then pick = p break end
        end
    end
    local drawn = false
    if pick then
        local ok, img = pcall(loadPng, gpu, pick)
        if ok and img then
            local iw, ih = img.getWidth(), img.getHeight()
            local x = math.floor((display.pw - iw) / 2) + 1
            local y = math.floor((display.ph - ih) / 2) + 1
            local okc, flat = pcall(compositeLogo, gpu, img, c.bg)
            if okc and flat then
                pcall(img.free)
                img = flat
            else
                ctx.log("logo composite failed: " .. tostring(flat))
            end
            local okd, derr = pcall(gpu.drawImage, x, y, img.ref())
            display.sync()
            pcall(img.free)
            drawn = okd
            ctx.log("logo " .. pick .. " drawn=" .. tostring(okd) .. " " .. tostring(derr))
        else
            ctx.log("logo load failed: " .. tostring(img))
        end
    end

    if not drawn and font then
        local title = "SimplyOS"
        local tw = font.width(title, "normal", 2)
        local ty = math.floor(display.h() / 2) - 16
        font.draw(math.floor((display.w() - tw) / 2) + 1, ty, title, c.text, c.bg, "normal", 2)
        local v = ctx.version.os
        local vw = font.width(v, "small", 1)
        font.draw(math.floor((display.w() - vw) / 2) + 1, ty + 40, v, c.muted, c.bg, "small", 1)
    end
    display.sync()
end

function K.run()
    local fsutil = lib("fsutil")
    local ver = { os = "26.1.0", ge = "26.1.0" }
    pcall(function() ver = dofile("/os/version.lua") end)

    local ctx = { version = ver, rot = 0, focus = "shell", overlay = false, blank = false }
    ctx.log = function(text) pcall(fsutil.log, "system", text) end
    ctx.fsutil = fsutil
    _G.SimplyOS = ctx

    local display = lib("display")
    display.init()
    ctx.display = display

    local okf, font = pcall(lib, "font")
    if okf and type(font) == "table" then
        pcall(font.init, display.gpu)
        display.font = font
        ctx.font = font
    else
        ctx.log("font failed: " .. tostring(font))
        error("font module failed: " .. tostring(font), 0)
    end

    local settings = lib("settings")
    local theme = lib("theme")
    local appslib = lib("apps")
    local notifylib = lib("notify")
    ctx.settings, ctx.theme = settings, theme

    local sched = dofile("/os/kernel/sched.lua")
    ctx.sched = sched

    pcall(bootScreen, ctx)

    function ctx.notify(rec)
        if not rec.appName then
            local a = rec.appId and appslib.find(rec.appId)
            rec.appName = a and a.name or (rec.appId or "System")
        end
        local r = notifylib.add(rec)
        if r then os.queueEvent("simplyos_notify", r.id) end
        return r
    end

    function ctx.toast(text) os.queueEvent("simplyos_toast", tostring(text)) end

    local function addRecent(id)
        local t = fsutil.readTable("/os/data/system/recents.lua") or { ids = {} }
        local out = { id }
        for _, v in ipairs(t.ids) do
            if v ~= id and #out < 6 then out[#out + 1] = v end
        end
        fsutil.writeTable("/os/data/system/recents.lua", { ids = out })
    end

    -- ---------- apps (one foreground app at a time) ----------
    local function startApp(id, file, meta)
        if ctx.fg then sched.kill(ctx.fg, nil) end
        local fn, err = loadfile(file, "t", ENV)
        if not fn then
            ctx.log("app " .. id .. " failed to load: " .. tostring(err))
            os.queueEvent("simplyos_app_exit", id, true, tostring(err))
            return false, err
        end
        ctx.fgMeta = meta or {}
        ctx.focus = "app"
        ctx.overlay = false
        if ctx.relayout then pcall(ctx.relayout) end
        local task
        task = sched.spawn(id, function() return fn() end, {
            kind = "app",
            onExit = function(t, e)
                if ctx.fg == t then
                    ctx.fg = nil
                    ctx.focus = "shell"
                    ctx.fgMeta = nil
                    if ctx.relayout then pcall(ctx.relayout) end
                end
                if e then
                    ctx.log("app " .. id .. " crashed: " .. tostring(e):match("^[^\n]*"))
                    pcall(fsutil.log, id, e)
                end
                os.queueEvent("simplyos_app_exit", id, e ~= nil, e)
            end,
        })
        if task.alive then
            ctx.fg = task
        elseif ctx.focus == "app" and not ctx.fg then
            ctx.focus = "shell"
        end
        return true
    end

    function ctx.launch(id)
        local a = appslib.find(id)
        if not a then return false, "not installed" end
        pcall(addRecent, id)
        local meta = a.meta or {}
        meta.fullscreen = a.fullscreen
        return startApp(id, a.dir .. "/" .. a.start, meta)
    end

    -- ---------- services and shell ----------
    local services = dofile("/os/kernel/services.lua")
    services.start(ctx)

    local shellRestarts = {}
    local startShell
    startShell = function()
        local chunk, err = loadfile("/os/shell/shell.lua", "t", ENV)
        ctx.shell = sched.spawn("shell", function()
            if not chunk then error(err, 0) end
            return chunk(ctx)
        end, {
            kind = "shell",
            onExit = function(_, e)
                ctx.shellErr = e or "shell exited"
                ctx.log("shell stopped: " .. tostring(ctx.shellErr):match("^[^\n]*"))
                local now = os.clock()
                local r = {}
                for _, v in ipairs(shellRestarts) do
                    if now - v < 60 then r[#r + 1] = v end
                end
                r[#r + 1] = now
                shellRestarts = r
                if #r >= 3 then sched.stop("shellfail") else startShell() end
            end,
        })
    end
    startShell()

    -- optional developer test task: /os/selftest.lua runs as a normal app
    if fs.exists("/os/selftest.lua") then startApp("selftest", "/os/selftest.lua", {}) end

    -- ---------- touch routing ----------
    local function route(ev)
        if ev[1] ~= "tm_monitor_touch" then return false end
        if ctx.blank then
            ctx.blank = false
            os.queueEvent("simplyos_wake")
            return true
        end
        local L = ctx.layout
        if not L then return true end
        local lx, ly = display.font.pointToLogical(ev[3], ev[4])
        if ly > L.H - L.navH then os.queueEvent("simplyos_navtap", lx, ly) return true end
        if not (L.full and ctx.focus == "app" and not ctx.overlay) and ly <= L.statusH then
            os.queueEvent("simplyos_statustap", lx, ly)
            return true
        end
        local b = ctx.banner
        if b and lx >= b.x and lx < b.x + b.w and ly >= b.y and ly < b.y + b.h then
            os.queueEvent("simplyos_bannertap")
            return true
        end
        local cx, cy = lx - L.cx + 1, ly - L.cy + 1
        if cx < 1 or cy < 1 or cx > L.cw or cy > L.ch then return true end
        local target = ctx.shell
        if ctx.focus == "app" and not ctx.overlay and ctx.fg then target = ctx.fg end
        sched.send(target, "tm_monitor_touch", ev[2], cx, cy, ev[5])
        return true
    end

    -- ---------- main loop ----------
    local terms = {}
    local reason = sched.run({
        route = route,
        onTerminate = function()
            -- Ctrl+T kills the foreground app. Three presses within 2 s leave to the CraftOS shell.
            local now = os.clock()
            local keep = {}
            for _, v in ipairs(terms) do
                if now - v < 2 then keep[#keep + 1] = v end
            end
            keep[#keep + 1] = now
            terms = keep
            if #terms >= 3 then sched.stop("exit") return end
            if ctx.fg then sched.kill(ctx.fg, nil) end
        end,
    })

    services.stop(ctx)

    if reason == "shellfail" then
        local crash = dofile("/os/kernel/crash.lua")
        local action = crash.recovery("shell failed: " .. tostring(ctx.shellErr))
        if action == "reset" then pcall(crash.factoryReset) end
        return "reboot"
    end
    return reason
end

return K
