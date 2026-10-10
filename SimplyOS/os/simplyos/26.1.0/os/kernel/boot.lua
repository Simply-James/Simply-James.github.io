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

local function bootScreen(ctx)
    local display, font = ctx.display, ctx.font
    local gpu = display.gpu
    local c = ctx.theme.colors()
    display.clear(c.bg)

    -- largest logo that is at most 50% of the short side. no runtime scaling.
    local limit = math.floor(math.min(display.pw, display.ph) * 0.5)
    local drawn = false
    for _, s in ipairs({ 256, 192, 128, 96 }) do
        local p = "/os/assets/logo_" .. s .. ".png"
        if s <= limit and fs.exists(p) then
            local ok, img = pcall(loadPng, gpu, p)
            if ok and img then
                local iw, ih = img.getWidth(), img.getHeight()
                pcall(gpu.drawImage, math.floor((display.pw - iw) / 2) + 1, math.floor((display.ph - ih) / 2) + 1, img.ref())
                display.sync()
                pcall(img.free)
                drawn = true
            end
            break
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
    local ver = { os = "26.1.0", ge = "none" }
    pcall(function() ver = dofile("/os/version.lua") end)

    local ctx = { version = ver }
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
    end

    local settings = lib("settings")
    local theme = lib("theme")
    ctx.settings, ctx.theme = settings, theme

    local sched = dofile("/os/kernel/sched.lua")
    ctx.sched = sched

    pcall(bootScreen, ctx)

    -- ---------- apps (one foreground app at a time) ----------
    local function readMeta(dir)
        local meta = {}
        pcall(function()
            local fn = loadfile(dir .. "metadata.lua", "t", {})
            if fn then
                local m = fn()
                if type(m) == "table" then meta = m end
            end
        end)
        return meta
    end

    local function startApp(id, file)
        if ctx.fg then sched.kill(ctx.fg, nil) end
        local fn, err = loadfile(file, "t", ENV)
        if not fn then
            ctx.log("app " .. id .. " failed to load: " .. tostring(err))
            os.queueEvent("simplyos_app_exit", id, true, tostring(err))
            return false, err
        end
        local task
        task = sched.spawn(id, function() return fn() end, {
            kind = "app",
            onExit = function(t, e)
                if ctx.fg == t then ctx.fg = nil end
                if e then
                    ctx.log("app " .. id .. " crashed: " .. tostring(e):match("^[^\n]*"))
                    if settings.get("dev.enabled") then pcall(fsutil.log, id, e) end
                end
                os.queueEvent("simplyos_app_exit", id, e ~= nil, e)
            end,
        })
        if task.alive then ctx.fg = task end
        return true
    end

    function ctx.launch(id)
        local dir = "/os/apps/" .. id .. "/"
        local meta = readMeta(dir)
        return startApp(id, dir .. (meta.start or "main.lua"))
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
    if fs.exists("/os/selftest.lua") then startApp("selftest", "/os/selftest.lua") end

    -- ---------- main loop ----------
    local terms = {}
    local reason = sched.run({
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
