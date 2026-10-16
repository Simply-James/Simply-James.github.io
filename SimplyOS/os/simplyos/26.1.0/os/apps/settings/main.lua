-- /os/apps/settings/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui
local ctx = E.ctx
local fsutil = dofile("/os/lib/fsutil.lua")
local appslib = dofile("/os/lib/apps.lua")
local simlib = dofile("/os/lib/sim.lua")
local notifylib = dofile("/os/lib/notify.lua")
local repo = dofile("/os/lib/repo.lua")
local sets = ctx.settings

local function set(key, value)
    E.settings.set(key, value)
    E.refresh()
    os.queueEvent("simplyos_settings")
end

local function human(n)
    if n >= 1048576 then return string.format("%.2f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.1f KB", n / 1024) end
    return n .. " B"
end

local ROT = { [0] = "Portrait", "Landscape (top left)", "Upside down", "Landscape (top right)" }

local function netState() return ctx.net and ctx.net.state() or { status = "off", bars = 0 } end
local STATUS = { online = "Connected", nosim = "No SIM", nomodem = "No wireless modem", searching = "Searching for server",
    login = "Signing in", starting = "Starting", off = "Off" }

-- blocking work with a progress screen. work(progress) -> ok, message. after() runs on OK when ok.
local function busy(title, work, after)
    local scene = E.scene{}
    local status, ok, done, frames = "Working...", false, false, 0
    local okBtn = ui.button{ label = "OK", style = "primary", onTap = function()
        E.pop()
        if ok and after then after() end
    end }
    scene.widgets = {}
    function scene:drawUI(g)
        local m, c = E.m, E.c
        g.text(m.pad, m.pad, g.fit(title, E.w - 2 * m.pad, "title"), "title", c.text, c.bg)
        local y = m.pad * 2 + g.lineHeight("title")
        for _, ln in ipairs(g.wrap(status, E.w - 2 * m.pad, "body")) do
            g.text(m.pad, y, ln, "body", c.muted, c.bg)
            y = y + g.lineHeight("body")
        end
        okBtn:setRect(m.pad, E.h - m.target - m.pad, E.w - 2 * m.pad, m.target)
    end
    function scene:update()
        frames = frames + 1
        if frames == 2 and not done then
            local good, a, b = pcall(work, function(text, frac)
                status = tostring(text) .. (frac and string.format("  %d%%", math.floor(frac * 100)) or "")
                E.drawNow()
            end)
            done = true
            if not good then ok, status = false, "Failed: " .. tostring(a)
            elseif a then ok, status = true, tostring(b or "Done")
            else ok, status = false, "Failed: " .. tostring(b) end
            scene.widgets = { okBtn }
            return true
        end
        return false
    end
    function scene:back() if done then E.pop() end return true end
    return scene
end

local function confirmThen(title, text, okText, fn, hold)
    E.push(ui.confirm{ title = title, text = text, okText = okText, danger = true, holdSecs = hold, onOk = fn })
end

-- ============================================================ pages
local pages = {}

pages.display = function()
    return ui.page{ title = "Display", build = function(page)
        return {
            { kind = "toggle", label = "Dark theme", on = sets.get("display.theme") == "dark",
                onChange = function(on) set("display.theme", on and "dark" or "light"); page.rebuild() end },
            { kind = "swatches", label = "Accent", selected = sets.get("display.accent"),
                options = { { name = "jblue", color = 0xFF0022FF }, { name = "jpink", color = 0xFFD400FF }, { name = "jpurple", color = 0xFF6A11FF } },
                onPick = function(n) set("display.accent", n); page.rebuild() end },
            { kind = "nav", label = "Scale", value = "Text, UI, home", onTap = function() E.push(pages.scale()) end },
            { kind = "toggle", label = "Back button on the left", on = sets.get("nav.order") == "bhr",
                onChange = function(on) set("nav.order", on and "bhr" or "rhb") end },
        }
    end }
end

pages.scale = function()
    local UI = { 100, 125, 150 }
    return ui.page{ title = "Scale", build = function(page)
        local level = sets.get("display.textLevel")
        local ui_ = sets.get("display.uiScale")
        local idx = 1
        for i, v in ipairs(UI) do if v == ui_ then idx = i end end
        return {
            { kind = "text", role = "title", text = "Title text" },
            { kind = "text", role = "body", text = "Body text looks like this." },
            { kind = "text", role = "caption", text = "Caption text looks like this." },
            { kind = "stepper", label = "Text size", value = level,
                onMinus = function() set("display.textLevel", math.max(1, level - 1)); page.rebuild() end,
                onPlus = function() set("display.textLevel", math.min(4, level + 1)); page.rebuild() end },
            { kind = "stepper", label = "UI size %", value = ui_,
                onMinus = function() set("display.uiScale", UI[math.max(1, idx - 1)]); page.rebuild() end,
                onPlus = function() set("display.uiScale", UI[math.min(3, idx + 1)]); page.rebuild() end },
            { kind = "stepper", label = "Home columns", value = sets.get("home.columns"),
                onMinus = function() set("home.columns", math.max(3, sets.get("home.columns") - 1)); page.rebuild() end,
                onPlus = function() set("home.columns", math.min(6, sets.get("home.columns") + 1)); page.rebuild() end },
        }
    end }
end

pages.orientation = function()
    local gim = peripheral.find("gimbal_sensor")
    local text, acc = "n/a", 0
    local function read()
        if not gim then return "no gimbal sensor" end
        local ok, a, b, c = pcall(gim.getGravity)
        if not ok then return "error" end
        if type(a) == "table" then a, b, c = a.x or a[1], a.y or a[2], a.z or a[3] end
        if type(a) ~= "number" then return "n/a" end
        return string.format("%.1f, %.1f, %.1f", a, b or 0, c or 0)
    end
    return ui.page{ title = "Orientation",
        build = function(page)
            return {
                { kind = "toggle", label = "Auto-rotate", on = sets.get("display.autoRotate"),
                    onChange = function(on) set("display.autoRotate", on) end },
                { kind = "info", label = "Detected", value = ROT[ctx.rot or 0] or "?" },
                { kind = "info", label = "Gravity x,y,z", value = text },
                { kind = "text", role = "caption", text = "Turn the phone to see the readout change. Record the upside-down and clockwise values." },
            }
        end,
        update = function(page, dt)
            acc = acc + dt
            if acc < 0.3 then return false end
            acc = 0
            local t = read()
            if t ~= text then text = t; page.rebuild(true) return true end
            return false
        end }
end

pages.clock = function()
    return ui.page{ title = "Clock", build = function()
        return {
            { kind = "toggle", label = "24-hour clock", on = sets.get("clock.format") == "24",
                onChange = function(on) set("clock.format", on and "24" or "12") end },
            { kind = "toggle", label = "Real-world time", on = sets.get("clock.source") == "irl",
                onChange = function(on) set("clock.source", on and "irl" or "ingame") end },
        }
    end }
end

pages.network = function()
    local acc = 0
    return ui.page{ title = "Network",
        build = function(page)
            local st = netState()
            local sim, why = simlib.read()
            local rows = {
                { kind = "info", label = "Status", value = STATUS[st.status] or tostring(st.status) },
                { kind = "info", label = "Signal", value = tostring(st.bars) .. " / 4" },
                { kind = "info", label = "Phone number", value = sim and sim.number or "none" },
                { kind = "info", label = "SIM", value = sim and "OK" or tostring(why) },
                { kind = "info", label = "Server", value = st.serverId and ("#" .. st.serverId) or "not found" },
                { kind = "nav", label = "Phone name", value = sets.get("phone.name"), onTap = function()
                    E.push(ui.textEntry{ title = "Phone name", text = sets.get("phone.name"), max = 24,
                        onDone = function(t) if t ~= "" then set("phone.name", t) end end })
                end },
                { kind = "toggle", label = "Server notifications", on = sets.get("notify.server"),
                    onChange = function(on) set("notify.server", on) end },
                { kind = "stepper", label = "Range (blocks, 0=off)", value = sets.get("net.maxRange"),
                    onMinus = function() set("net.maxRange", math.max(0, sets.get("net.maxRange") - 16)); page.rebuild() end,
                    onPlus = function() set("net.maxRange", sets.get("net.maxRange") + 16); page.rebuild() end },
            }
            if st.dist then rows[#rows + 1] = { kind = "info", label = "Distance", value = string.format("%.0f", st.dist) } end
            if st.lastErr then rows[#rows + 1] = { kind = "text", role = "caption", text = "Last error: " .. tostring(st.lastErr) } end
            return rows
        end,
        update = function(page, dt)
            acc = acc + dt
            if acc > 1 then acc = 0; page.rebuild(true) return true end
            return false
        end }
end

pages.notifications = function()
    return ui.page{ title = "Notifications", build = function(page)
        local rows = { { kind = "button", label = "Clear all notifications", onTap = function() notifylib.clear(); E.toast("Cleared") end } }
        for _, a in ipairs(appslib.list()) do
            if not a.dev then
                local key = "notify.mute." .. a.id
                rows[#rows + 1] = { kind = "toggle", label = a.name, on = not sets.get(key),
                    onChange = function(on) set(key, not on) end }
            end
        end
        return rows
    end }
end

pages.appDetail = function(a)
    return ui.page{ title = a.name, build = function(page)
        local dataSize = fsutil.size("/os/data/" .. a.id)
        local cacheSize = fsutil.size("/os/data/" .. a.id .. "/cache")
        local rows = {
            { kind = "info", label = "Version", value = a.version },
            { kind = "info", label = "App size", value = human(fsutil.size(a.dir)) },
            { kind = "info", label = "Data", value = human(dataSize - cacheSize) },
            { kind = "info", label = "Cache", value = human(cacheSize) },
            { kind = "button", label = "Clear cache", onTap = function()
                pcall(fs.delete, "/os/data/" .. a.id .. "/cache"); page.rebuild(true)
            end },
            { kind = "button", label = "Clear data", style = "danger", onTap = function()
                confirmThen("Clear data?", "Deletes everything " .. a.name .. " saved.", "Clear", function()
                    pcall(fs.delete, "/os/data/" .. a.id)
                end)
            end },
        }
        if not a.system then
            rows[#rows + 1] = { kind = "button", label = "Uninstall", style = "danger", onTap = function()
                confirmThen("Uninstall " .. a.name .. "?", "Keeps its data.", "Uninstall", function()
                    local ok, err = repo.uninstall(a.id, false)
                    E.pop()
                    E.toast(ok and (a.name .. " uninstalled") or tostring(err))
                end)
            end }
            rows[#rows + 1] = { kind = "button", label = "Uninstall and delete data", style = "danger", onTap = function()
                confirmThen("Uninstall " .. a.name .. "?", "Also deletes its data.", "Uninstall", function()
                    local ok, err = repo.uninstall(a.id, true)
                    E.pop()
                    E.toast(ok and (a.name .. " uninstalled") or tostring(err))
                end)
            end }
        end
        return rows
    end }
end

pages.apps = function()
    return ui.page{ title = "Apps", build = function()
        local rows = {}
        for _, a in ipairs(appslib.list()) do
            rows[#rows + 1] = { kind = "nav", label = a.name, value = human(fsutil.size(a.dir)),
                onTap = function() E.push(pages.appDetail(a)) end }
        end
        return rows
    end }
end

pages.storage = function()
    return ui.page{ title = "Storage", build = function()
        local cap, free = fsutil.capacity(), fsutil.free()
        local rows = {}
        local sz = fsutil.size
        local caches = 0
        if fs.isDir("/os/data") then
            for _, d in ipairs(fs.list("/os/data")) do caches = caches + sz("/os/data/" .. d .. "/cache") end
        end
        local msgs = sz("/os/data/messages")
        local osSize = sz("/os/kernel") + sz("/os/lib") + sz("/os/shell") + sz("/os/assets") + sz("/startup.lua") + sz("/os/version.lua")
        local geSize = sz("/os/engine")
        local appsSize = sz("/os/apps")
        local dataSize = math.max(0, sz("/os/data") - msgs - caches)
        local logs = sz("/os/logs")
        if cap and free ~= math.huge then
            rows[#rows + 1] = { kind = "bar", label = "Used", value = human(cap - free) .. " of " .. human(cap), frac = (cap - free) / cap }
            rows[#rows + 1] = { kind = "info", label = "Free", value = human(free) }
            if free < 50000 then rows[#rows + 1] = { kind = "text", role = "caption", text = "Storage is almost full." } end
        end
        for _, r in ipairs({ { "System", osSize }, { "Engine", geSize }, { "Apps", appsSize }, { "App data", dataSize },
            { "Caches", caches }, { "Messages", msgs }, { "Logs", logs } }) do
            rows[#rows + 1] = { kind = "info", label = r[1], value = human(r[2]) }
        end
        return rows
    end }
end

local pending, restartNeeded = nil, false

pages.browse = function(items)
    return ui.page{ title = "Get apps", build = function()
        local rows = {}
        if #items == 0 then rows[1] = { kind = "text", text = "Nothing available." } end
        local installed = {}
        for _, a in ipairs(appslib.list()) do installed[a.id] = a.version end
        for _, it in ipairs(items) do
            local tag = installed[it.id] and (installed[it.id] == it.version and "installed" or "update") or it.version
            rows[#rows + 1] = { kind = "nav", label = it.name or it.id, value = tag, onTap = function()
                E.push(busy("Installing " .. (it.name or it.id), function(progress)
                    local ok, ver, restart = repo.install(it.kind or "app", it.id, progress)
                    if ok then
                        if restart then restartNeeded = true end
                        return true, "Installed " .. tostring(ver) .. (restart and ". Restart to apply." or "")
                    end
                    return false, ver
                end))
            end }
        end
        return rows
    end }
end

pages.update = function()
    return ui.page{ title = "Software update", build = function(page)
        local v = repo.localVersions()
        local rows = {
            { kind = "info", label = "SimplyOS", value = v.os },
            { kind = "info", label = "Engine", value = v.ge },
            { kind = "button", label = "Check for updates", style = "primary", onTap = function()
                E.push(busy("Checking", function()
                    local items, err = repo.updates()
                    if not items then return false, err end
                    pending = items
                    return true, #items == 0 and "Everything is up to date." or (#items .. " update(s) available")
                end))
            end },
        }
        if pending then
            for _, it in ipairs(pending) do
                rows[#rows + 1] = { kind = "nav", label = (it.name or it.id), value = tostring(it.version), onTap = function()
                    E.push(busy("Installing " .. (it.name or it.id), function(progress)
                        local ok, ver, restart = repo.install(it.kind, it.id, progress)
                        if ok then
                            if restart then restartNeeded = true end
                            for i, p in ipairs(pending) do if p == it then table.remove(pending, i) break end end
                            return true, "Installed " .. tostring(ver) .. (restart and ". Restart to apply." or "")
                        end
                        return false, ver
                    end))
                end }
            end
        end
        rows[#rows + 1] = { kind = "button", label = "Get apps", onTap = function()
            local items
            E.push(busy("Loading", function()
                local d, err = repo.list("app", 1)
                if not d then return false, err end
                items = d.items or {}
                return true, #items .. " app(s)"
            end, function() E.push(pages.browse(items)) end))
        end }
        if restartNeeded then
            rows[#rows + 1] = { kind = "button", label = "Restart now", style = "danger", onTap = function() os.reboot() end }
        end
        local st = netState()
        if sets.get("dev.enabled") and st.admin then
            rows[#rows + 1] = { kind = "button", label = "Direct download (developer)", onTap = function()
                E.push(ui.textEntry{ title = "App id", max = 40, onDone = function(id)
                    if id == "" then return end
                    E.push(ui.textEntry{ title = "Version (26.1.0)", max = 12, allow = "[%d%.]", onDone = function(ver)
                        E.push(busy("Downloading " .. id, function(progress)
                            local info, err = repo.info()
                            if not info or not info.baseUrl then return false, err or "no base url" end
                            local ok, res = repo.installDirect(info.baseUrl, id, ver, progress)
                            if ok then return true, "Installed " .. tostring(res) end
                            return false, res
                        end))
                    end })
                end })
            end }
        end
        return rows
    end }
end

pages.developer = function()
    return ui.page{ title = "Developer", build = function(page)
        return {
            { kind = "toggle", label = "Developer mode", on = sets.get("dev.enabled"),
                onChange = function(on) set("dev.enabled", on) end },
            { kind = "toggle", label = "FPS overlay", on = sets.get("dev.fpsOverlay"), onChange = function(on) set("dev.fpsOverlay", on) end },
            { kind = "toggle", label = "Logging", on = sets.get("dev.logging"), onChange = function(on) set("dev.logging", on) end },
            { kind = "toggle", label = "Watchdog", on = sets.get("dev.watchdog"), onChange = function(on) set("dev.watchdog", on) end },
            { kind = "text", role = "caption", text = "The watchdog only arms when its timeout is above 0. Changes apply after a restart." },
            { kind = "button", label = "Open Log Viewer", onTap = function() ctx.launch("logviewer") end },
        }
    end }
end

pages.about = function()
    local taps = 0
    return ui.page{ title = "About phone", build = function(page)
        local sim = simlib.read()
        local vram = "n/a"
        pcall(function()
            local gpu = ctx.display.gpu
            vram = string.format("%.1f / %.0f MB", gpu.getUsedMemory() / 1048576, gpu.getMaxMemory() / 1048576)
        end)
        local v = repo.localVersions()
        return {
            { kind = "info", label = "Phone name", value = sets.get("phone.name") },
            { kind = "info", label = "Phone number", value = sim and sim.number or "none" },
            { kind = "info", label = "Screen", value = ctx.display.pw .. "x" .. ctx.display.ph .. " " .. (ROT[ctx.rot or 0] or "") },
            { kind = "info", label = "Video memory", value = vram },
            { kind = "info", label = "Computer ID", value = tostring(os.getComputerID()) },
            { kind = "info", label = "CraftOS", value = tostring(os.version()) },
            { kind = "info", label = "SimplyOS", value = v.os },
            { kind = "info", label = "Engine", value = v.ge },
            { kind = "nav", label = "Build number", value = v.os, onTap = function()
                if sets.get("dev.enabled") then E.toast("Developer mode is already on") return end
                taps = taps + 1
                if taps >= 7 then
                    set("dev.enabled", true)
                    E.toast("Developer mode on")
                elseif taps >= 3 then
                    E.toast((7 - taps) .. " more taps")
                end
            end },
        }
    end }
end

pages.reset = function()
    return ui.page{ title = "Reset", build = function()
        return {
            { kind = "button", label = "Reset settings", onTap = function()
                confirmThen("Reset settings?", "All settings return to defaults. Apps and data stay.", "Reset", function()
                    sets.reset()
                    set("display.theme", "dark")
                    E.toast("Settings reset")
                end)
            end },
            { kind = "button", label = "Factory reset", style = "danger", onTap = function()
                confirmThen("Factory reset?", "Deletes all data, settings, messages, notifications and user apps. Keeps the OS, bundled apps and the SIM.",
                    "Hold to erase", function()
                        dofile("/os/kernel/crash.lua").factoryReset()
                        os.reboot()
                    end, 3)
            end },
        }
    end }
end

-- ============================================================ main
local main = ui.page{ title = "Settings", build = function()
    local rows = {
        { kind = "nav", label = "Display", onTap = function() E.push(pages.display()) end },
        { kind = "nav", label = "Orientation", onTap = function() E.push(pages.orientation()) end },
        { kind = "nav", label = "Clock", onTap = function() E.push(pages.clock()) end },
        { kind = "nav", label = "Network", value = STATUS[netState().status] or "", onTap = function() E.push(pages.network()) end },
        { kind = "nav", label = "Notifications", onTap = function() E.push(pages.notifications()) end },
        { kind = "nav", label = "Apps", onTap = function() E.push(pages.apps()) end },
        { kind = "nav", label = "Storage", onTap = function() E.push(pages.storage()) end },
        { kind = "nav", label = "Software update", onTap = function() E.push(pages.update()) end },
    }
    if sets.get("dev.enabled") then
        rows[#rows + 1] = { kind = "nav", label = "Developer", onTap = function() E.push(pages.developer()) end }
    end
    rows[#rows + 1] = { kind = "nav", label = "About phone", onTap = function() E.push(pages.about()) end }
    rows[#rows + 1] = { kind = "nav", label = "Reset", onTap = function() E.push(pages.reset()) end }
    return rows
end }

E.run{ id = "settings", start = main }
