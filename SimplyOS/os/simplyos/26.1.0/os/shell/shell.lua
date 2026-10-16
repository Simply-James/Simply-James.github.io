-- /os/shell/shell.lua
-- SimplyOS shell: status bar, navigation bar, home screen (grid, pages, dock), notification centre,
-- recents, banner, toasts, rotation, power button. Runs as one task for the whole session.
local ctx = ...
local display, font, theme, settings, sched = ctx.display, ctx.font, ctx.theme, ctx.settings, ctx.sched
local gfxmod = dofile("/os/engine/gfx.lua")
local inputmod = dofile("/os/engine/input.lua")
local appslib = dofile("/os/lib/apps.lua")
local notifylib = dofile("/os/lib/notify.lua")
local timefmt = dofile("/os/lib/timefmt.lua")
local messagesLib = dofile("/os/lib/messages.lua")

local g = gfxmod.new(ctx)
local SE = { c = theme.colors(), m = theme.metrics(), dirty = function() end }
SE.scene = function(t) return t end
local ui = dofile("/os/engine/ui.lua")(SE)

local L
local wantRot, pendingRot, pendingN = 0, 0, 0
local view = "home"                 -- "home" | "notif" | "recents"
local page = 1
local flash, flashUntil = nil, 0
local banner, bannerUntil = nil, 0
local toast, toastUntil = nil, 0
local closeDeadline = nil
local lastNav = -10
local lastMinute = -1
local lastHour = -1
local homeHits, homeInfo = {}, {}
local overlayList
local gim = peripheral.find("gimbal_sensor")
local lastRs = false

local DOCK = { "messages", "files", "notes", "settings" }

-- ============================================================ layout
local function computeLayout(full)
    local W, H = display.w(), display.h()
    local m = theme.metrics()
    local cy = full and 1 or (m.statusBar + 1)
    L = { W = W, H = H, statusH = m.statusBar, navH = m.navBar, full = full and true or false,
        cx = 1, cy = cy, cw = W, ch = H - m.navBar - (cy - 1) }
    ctx.layout = L
    SE.c, SE.m = theme.colors(), m
end

local function setContentView()
    g.setView(L.cx, L.cy, L.cw, L.ch)
    g.level = settings.get("display.textLevel")
    g.c = SE.c
end

local function setFullView()
    g.setView(1, 1, L.W, L.H)
    g.level = settings.get("display.textLevel")
    g.c = SE.c
end

-- ============================================================ chrome
local function drawStatus()
    if L.full and ctx.focus == "app" and not ctx.overlay then return end
    setFullView()
    local c, m = SE.c, SE.m
    g.rect(1, 1, L.W, L.statusH, c.bg)
    local h, mn = timefmt.now()
    local txt = timefmt.fmt(h, mn)
    local lh = g.lineHeight("caption")
    local ty = math.floor((L.statusH - lh) / 2) + 1
    g.text(m.pad, ty, txt, "caption", c.text, c.bg)
    -- signal bars
    local N = ctx.net and ctx.net.state()
    local bars = N and N.bars or 0
    local bw = math.max(3, theme.scale(4))
    local x = L.W - m.pad - 4 * (bw + 2)
    for i = 1, 4 do
        local bh = math.max(3, math.floor((L.statusH - 8) * i / 4))
        g.rect(x + (i - 1) * (bw + 2), L.statusH - 4 - bh, bw, bh, i <= bars and c.text or c.raised)
    end
    if N and N.status == "nosim" then
        local s = "No SIM"
        g.text(x - 8 - g.textWidth(s, "caption"), ty, s, "caption", c.muted, c.bg)
    end
    -- unread dots
    local n = math.min(5, notifylib.unread())
    if n > 0 then
        local ds = math.max(4, theme.scale(5))
        local total = n * (ds + 3) - 3
        local dx = math.floor((L.W - total) / 2)
        for i = 1, n do
            g.roundRect(dx + (i - 1) * (ds + 3), math.floor((L.statusH - ds) / 2) + 1, ds, ds, math.floor(ds / 2), c.accent)
        end
    end
end

local function navOrder()
    if settings.get("nav.order") == "bhr" then return { "back", "home", "recents" } end
    return { "recents", "home", "back" }
end

local function drawNav()
    setFullView()
    local c = SE.c
    local y0 = L.H - L.navH + 1
    g.rect(1, y0, L.W, L.navH, c.bg)
    local order = navOrder()
    local zw = L.W / 3
    local s = math.floor(L.navH * 0.38)
    local cy = y0 + math.floor(L.navH / 2)
    for i, name in ipairs(order) do
        local cx = math.floor((i - 0.5) * zw)
        if flash == name and os.clock() < flashUntil then
            local r = L.navH - 8
            g.roundRect(cx - math.floor(r / 2), cy - math.floor(r / 2), r, r, math.floor(r / 2), c.raised)
        end
        if name == "recents" then
            for k = -1, 1 do g.rect(cx + k * (math.floor(s / 2) + 2) - 1, cy - math.floor(s / 2), 3, s, c.text) end
        elseif name == "home" then
            g.roundRect(cx - math.floor(s / 2), cy - math.floor(s / 2), s, s, math.floor(s / 2), c.text)
            g.roundRect(cx - math.floor(s / 2) + 2, cy - math.floor(s / 2) + 2, s - 4, s - 4, math.floor(s / 2) - 2, c.bg)
        else
            local q = math.floor(s / 3)
            g.line(cx + q, cy - math.floor(s / 2), cx - q, cy, 3, c.text)
            g.line(cx - q, cy, cx + q, cy + math.floor(s / 2), 3, c.text)
        end
    end
end

local function drawChrome()
    drawStatus()
    drawNav()
end
ctx.chromeDraw = function() drawChrome(); display.sync() end

-- ============================================================ home screen
local function homeApps()
    local all = appslib.list()
    local dev = settings.get("dev.enabled")
    local byId, dock, grid = {}, {}, {}
    for _, a in ipairs(all) do byId[a.id] = a end
    local inDock = {}
    for _, id in ipairs(DOCK) do
        if byId[id] then dock[#dock + 1] = byId[id]; inDock[id] = true end
    end
    for _, a in ipairs(all) do
        if not inDock[a.id] and (dev or not a.dev) then grid[#grid + 1] = a end
    end
    return dock, grid
end

-- icon table for an app: Clock shows the current hour, Messages shows a dot when something is unread
local function iconApp(a, msgUnread)
    local t = { id = a.id, name = a.name, icon = a.icon }
    -- hourly icons: /os/apps/<id>/icons/h01.png .. h12.png (found by folder, no metadata needed)
    if fs.exists(a.dir .. "/icons/h01.png") then
        local hr = timefmt.now()
        local p = string.format("%s/icons/h%02d.png", a.dir, ((hr - 1) % 12) + 1)
        if fs.exists(p) then t.icon = p end
    end
    if a.id == "messages" and msgUnread > 0 and fs.exists(a.dir .. "/AppIconNotify.png") then
        t.icon = a.dir .. "/AppIconNotify.png"
    end
    return t
end

local function drawHome()
    setContentView()
    local c, m = SE.c, SE.m
    g.clear(c.bg)
    homeHits = {}
    local dock, grid = homeApps()
    local okm, msgUnread = pcall(messagesLib.unreadTotal)
    if not okm then msgUnread = 0 end
    local cols = settings.get("home.columns")
    local margin = math.max(24, m.pad)
    local gap = math.max(6, math.floor(m.pad * 0.6))
    local icon = math.max(24, math.floor((L.cw - 2 * margin - (cols - 1) * gap) / cols))
    local labelH = g.lineHeight("caption")
    -- keep one grid row and the dock on screen (short landscape screens); then more columns fit
    local maxIcon = math.floor((L.ch - 14 - m.pad * 3 - labelH - 4 - gap) / 2)
    if icon > maxIcon then
        icon = math.max(24, maxIcon)
        cols = math.max(1, math.floor((L.cw - 2 * margin + gap) / (icon + gap)))
    end
    local cellH = icon + 4 + labelH + gap
    local dockH = icon + 2 * m.pad
    local dotsH = 14
    local areaH = L.ch - dockH - dotsH - m.pad
    local rows = math.max(1, math.floor(areaH / cellH))
    local per = rows * cols
    local pages = math.max(1, math.ceil(#grid / per))
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    homeInfo = { pages = pages }
    local first = (page - 1) * per + 1
    local gridW = cols * icon + (cols - 1) * gap
    local x0 = math.floor((L.cw - gridW) / 2) + 1
    local y0 = m.pad
    for i = first, math.min(#grid, first + per - 1) do
        local k = i - first
        local col, row = k % cols, math.floor(k / cols)
        local x = x0 + col * (icon + gap)
        local y = y0 + row * cellH
        local a = grid[i]
        g.icon(iconApp(a, msgUnread), x, y, icon, c.bg)
        local label = g.fit(a.name, icon, "caption")
        g.textCentered(x + math.floor(icon / 2), y + icon + 4, label, "caption", c.text, c.bg)
        homeHits[#homeHits + 1] = { x = x, y = y, w = icon, h = icon + 4 + labelH, app = a }
    end
    -- page dots
    if pages > 1 then
        local ds = 6
        local total = pages * (ds + 6) - 6
        local dx = math.floor((L.cw - total) / 2) + 1
        local dy = L.ch - dockH - dotsH + 2
        for p = 1, pages do
            g.roundRect(dx + (p - 1) * (ds + 6), dy, ds, ds, 3, p == page and c.text or c.raised)
        end
        local midY = math.floor((y0 + areaH) / 2)
        if page > 1 then g.text(4, midY, "<", "body", c.muted, c.bg) end
        if page < pages then g.text(L.cw - 4 - g.textWidth(">", "body"), midY, ">", "body", c.muted, c.bg) end
    end
    -- dock
    local dy = L.ch - dockH + 1
    g.roundRect(m.pad, dy, L.cw - 2 * m.pad, dockH - math.floor(m.pad / 2), m.radius, c.card)
    local slots = 4
    local free = (L.cw - 2 * m.pad) - slots * icon
    local sp = math.floor(free / (slots + 1))
    for i, a in ipairs(dock) do
        local x = m.pad + sp + (i - 1) * (icon + sp)
        local y = dy + math.floor(m.pad / 2)
        g.icon(iconApp(a, msgUnread), x, y, icon, c.card)
        homeHits[#homeHits + 1] = { x = x, y = y, w = icon, h = icon, app = a }
    end
end

local function homeTouch(x, y)
    local pages = homeInfo.pages or 1
    if pages > 1 then
        if x <= 24 and page > 1 then page = page - 1; drawHome(); display.sync() return end
        if x > L.cw - 24 and page < pages then page = page + 1; drawHome(); display.sync() return end
    end
    for _, h in ipairs(homeHits) do
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
            local ok = ctx.launch(h.app.id)
            if not ok then ctx.toast("Could not open " .. h.app.name) end
            return
        end
    end
end

-- ============================================================ overlays
local function closeOverlay()
    if not ctx.overlay then return end
    ctx.overlay = false
    view = "home"
    overlayList = nil
    if ctx.focus == "app" then os.queueEvent("simplyos_redraw") else drawHome() end
    display.sync()
end

local drawOverlay

local function buildNotif()
    local rows = {}
    local items = notifylib.list()
    rows[1] = { kind = "button", label = "Clear all", onTap = function() notifylib.clear(); drawOverlay() end }
    if #items == 0 then rows[#rows + 1] = { kind = "text", text = "No notifications", role = "body" } end
    for _, r in ipairs(items) do
        rows[#rows + 1] = {
            kind = "item", title = (r.appName or "") .. (r.title and (" - " .. r.title) or ""), text = r.text or "",
            right = "x",
            onRight = function() notifylib.remove(r.id); drawOverlay() end,
            onTap = function()
                notifylib.remove(r.id)
                closeOverlay()
                if r.appId and appslib.find(r.appId) then ctx.launch(r.appId) end
            end,
        }
    end
    return rows
end

local function buildRecents()
    local rows = {}
    local t = ctx.fsutil.readTable("/os/data/system/recents.lua") or { ids = {} }
    rows[1] = { kind = "button", label = "Close all", onTap = function()
        ctx.fsutil.writeTable("/os/data/system/recents.lua", { ids = {} })
        if ctx.fg then sched.kill(ctx.fg, nil) end
        drawOverlay()
    end }
    local any = false
    for _, id in ipairs(t.ids) do
        local a = appslib.find(id)
        if a then
            any = true
            local isz = math.max(32, SE.m.target)
            rows[#rows + 1] = { kind = "custom", h = isz + 12, onTap = function()
                closeOverlay()
                ctx.launch(a.id)
            end, draw = function(gg, x, y, w, h)
                SE.c = SE.c
                ui.card(gg, x, y, w, h, SE.c.card)
                gg.icon(iconApp(a, 0), x + 8, y + 6, isz, SE.c.card)
                gg.text(x + 16 + isz, y + math.floor((h - gg.lineHeight("body")) / 2), gg.fit(a.name, w - isz - 28, "body"),
                    "body", SE.c.text, SE.c.card)
            end }
        end
    end
    if not any then rows[#rows + 1] = { kind = "text", text = "No recent apps", role = "body" } end
    return rows
end

drawOverlay = function()
    setContentView()
    SE.c, SE.m = theme.colors(), theme.metrics()
    g.c = SE.c
    g.clear(SE.c.bg)
    local m = SE.m
    local title = view == "notif" and "Notifications" or "Recent apps"
    g.text(m.pad, m.pad, title, "title", SE.c.text, SE.c.bg)
    local top = m.pad * 2 + g.lineHeight("title")
    overlayList = overlayList or ui.list{}
    overlayList:setRows(view == "notif" and buildNotif() or buildRecents(), true)
    overlayList:setRect(m.pad, top, L.cw - 2 * m.pad, L.ch - top - m.pad)
    overlayList:draw(g)
    display.sync()
end

local function openOverlay(which)
    if ctx.overlay and view == which then closeOverlay() return end
    view = which
    ctx.overlay = true
    overlayList = nil
    if which == "notif" then notifylib.markAllRead() drawStatus() end
    drawOverlay()
end

-- ============================================================ banner and toast
local function restoreContent()
    if ctx.overlay then drawOverlay()
    elseif ctx.focus == "app" then os.queueEvent("simplyos_redraw")
    else drawHome() end
    drawChrome()
    display.sync()
end

local function drawBanner()
    if not banner then return end
    setFullView()
    local c, m = SE.c, SE.m
    local isz = math.max(24, theme.scale(32))
    local h = isz + 12
    local x, y, w = m.pad, L.statusH + 4, L.W - 2 * m.pad
    ctx.banner = { x = x, y = y, w = w, h = h, appId = banner.appId }
    g.roundRect(x, y, w, h, m.radius, c.raised)
    local app = banner.appId and appslib.find(banner.appId) or { name = banner.appName or "?" }
    g.icon(app, x + 6, y + 6, isz, c.raised)
    local tx = x + 12 + isz
    g.text(tx, y + 5, g.fit(banner.appName or "", w - isz - 24, "caption"), "caption", c.muted, c.raised)
    local line = (banner.title and (banner.title .. ": ") or "") .. (banner.text or "")
    g.text(tx, y + 5 + g.lineHeight("caption"), g.fit(line, w - isz - 24, "body"), "body", c.text, c.raised)
    display.sync()
end

local function drawToast()
    if not toast then return end
    setFullView()
    local c, m = SE.c, SE.m
    local tw = g.textWidth(toast, "body") + 2 * m.pad
    tw = math.min(tw, L.W - 2 * m.pad)
    local th = g.lineHeight("body") + m.pad
    local x = math.floor((L.W - tw) / 2) + 1
    local y = L.H - L.navH - th - m.pad
    g.roundRect(x, y, tw, th, math.floor(th / 2), 0xFF3A3A44)
    g.text(x + m.pad, y + math.floor(m.pad / 2), g.fit(toast, tw - 2 * m.pad, "body"), "body", 0xFFFFFFFF, 0xFF3A3A44)
    display.sync()
end

-- ============================================================ relayout (kernel calls this on app start/exit)
local function allowedRotation()
    local rot = wantRot
    if ctx.focus == "app" then
        local ok = false
        for _, o in ipairs((ctx.fgMeta and ctx.fgMeta.orientations) or { "portrait" }) do
            if o == "landscape" then ok = true end
        end
        if not ok then rot = 0 end
    end
    if not settings.get("display.autoRotate") and ctx.focus ~= "app" then rot = 0 end
    return rot
end

function ctx.relayout()
    local rot = allowedRotation()
    display.setRotation(rot)
    ctx.rot = rot
    computeLayout(ctx.focus == "app" and ctx.fgMeta and ctx.fgMeta.fullscreen)
    SE.c = theme.colors()
    display.clear(SE.c.bg)
    drawChrome()
    if ctx.focus == "app" and not ctx.overlay then
        os.queueEvent("simplyos_relayout")
    elseif ctx.overlay then
        drawOverlay()
    else
        drawHome()
    end
    display.sync()
end

-- ============================================================ rotation
local function readRotation()
    if not gim then return nil end
    local ok, a, b, c = pcall(gim.getGravity)
    if not ok then return nil end
    local gx, gy, gz
    if type(a) == "table" then gx, gy, gz = a.x or a[1], a.y or a[2], a.z or a[3] else gx, gy, gz = a, b, c end
    if type(gy) ~= "number" or type(gz) ~= "number" then return nil end
    if gy < -6 then return 0 end
    if gz < -6 then return 1 end
    if gz > 6 then return 3 end
    if gy > 6 then return 2 end
    return nil
end

local function pollRotation()
    if not settings.get("display.autoRotate") then
        if wantRot ~= 0 then wantRot = 0; ctx.relayout() end
        return
    end
    local r = readRotation()
    if r == nil or r == wantRot then pendingN = 0 return end
    if r == pendingRot then pendingN = pendingN + 1 else pendingRot, pendingN = r, 1 end
    if pendingN >= 2 then
        wantRot, pendingN = r, 0
        if allowedRotation() ~= ctx.rot then ctx.relayout() end
    end
end

-- ============================================================ blank / power button
local function blankScreen()
    ctx.blank = true
    display.clear(0xFF000000)
    display.sync()
end

local function wake()
    if not ctx.blank then return end
    ctx.blank = false
    ctx.relayout()
end

-- ============================================================ input
local input = inputmod.new(function(kind, a, b, c2, d)
    if ctx.blank then return end
    if ctx.overlay then
        if not overlayList then return end
        if kind == "touch" then overlayList:touch(a, b)
        elseif kind == "drag" then overlayList:drag(a, b, c2, d)
        elseif kind == "hold" then overlayList:hold(a, b, c2)
        elseif kind == "release" then overlayList:release() end
        drawOverlay()
    elseif kind == "touch" and ctx.focus == "shell" then
        homeTouch(a, b)
    end
end)

local function doNav(name)
    flash, flashUntil = name, os.clock() + 0.12
    drawNav()
    display.sync()
    if name == "back" then
        if ctx.overlay then closeOverlay()
        elseif ctx.focus == "app" then os.queueEvent("simplyos_back")
        elseif page > 1 then page = page - 1; drawHome(); display.sync() end
    elseif name == "home" then
        if ctx.overlay then
            ctx.overlay = false
            view = "home"
            overlayList = nil
        end
        if ctx.focus == "app" then
            os.queueEvent("simplyos_exit")
            closeDeadline = os.clock() + 0.5
        else
            page = 1
            drawHome()
            display.sync()
        end
    elseif name == "recents" then
        openOverlay("recents")
    end
end

-- ============================================================ main
local function showFirst()
    ctx.relayout()
end

sleep(1.5)   -- keep the boot logo visible
showFirst()
os.queueEvent("simplyos_shell_ready")

local tick = os.startTimer(0.1)
local ticks = 0
local running = true
while running do
    local ev = table.pack(os.pullEvent())
    local name = ev[1]
    local now = os.clock()
    if name == "timer" and ev[2] == tick then
        tick = os.startTimer(0.1)
        ticks = ticks + 1
        if not ctx.blank then
            input.tick(now)
            if flash and now >= flashUntil then flash = nil; drawNav(); display.sync() end
            if banner and now >= bannerUntil then banner = nil; ctx.banner = nil; restoreContent() end
            if toast and now >= toastUntil then toast = nil; restoreContent() end
            if ticks % 5 == 0 then
                local _, mn = timefmt.now()
                if mn ~= lastMinute then
                    lastMinute = mn
                    drawStatus()
                    local hr = timefmt.now()
                    if hr ~= lastHour then
                        lastHour = hr
                        if ctx.focus == "shell" and not ctx.overlay then drawHome() end
                    end
                    display.sync()
                end
            end
        end
        if closeDeadline and now >= closeDeadline then
            closeDeadline = nil
            if ctx.fg then sched.kill(ctx.fg, nil) end
        end
        if ticks % 3 == 0 and not ctx.blank then pollRotation() end
    elseif name == "tm_monitor_touch" then
        input.feed(ev, now)
    elseif name == "simplyos_navtap" then
        if now - lastNav > 0.3 then
            local zw = L.W / 3
            local idx = math.min(3, math.max(1, math.floor((ev[2] - 1) / zw) + 1))
            doNav(navOrder()[idx])
        end
        lastNav = now
    elseif name == "simplyos_statustap" then
        if now - lastNav > 0.3 then openOverlay("notif") end
        lastNav = now
    elseif name == "simplyos_bannertap" then
        local b = banner
        banner, ctx.banner = nil, nil
        if b and b.appId and appslib.find(b.appId) then ctx.launch(b.appId) else restoreContent() end
    elseif name == "simplyos_notify" and not ctx.blank then
        local items = notifylib.list()
        banner = items[1]
        if banner and banner.id == ev[2] then
            bannerUntil = now + 3
            drawStatus()
            drawBanner()
        end
    elseif name == "simplyos_status" and not ctx.blank then
        drawStatus()
        display.sync()
    elseif name == "simplyos_toast" and not ctx.blank then
        toast, toastUntil = ev[2], now + 2
        drawToast()
    elseif name == "simplyos_settings" then
        ctx.relayout()
    elseif name == "simplyos_msg" and not ctx.blank then
        if ctx.focus == "shell" and not ctx.overlay then drawHome() end
        drawStatus()
        display.sync()
    elseif name == "simplyos_app_exit" then
        if ev[3] and not settings.get("dev.enabled") then
            local a = appslib.find(ev[2])
            toast, toastUntil = (a and a.name or tostring(ev[2])) .. " stopped", now + 2
        end
        if not ctx.blank then restoreContent() end
        if toast then drawToast() end
    elseif name == "simplyos_wake" then
        wake()
    elseif name == "redstone" then
        local side = settings.get("hardware.powerButtonSide")
        if side ~= "none" then
            local ok, v = pcall(redstone.getInput, side)
            if ok then
                if v and not lastRs then
                    if ctx.blank then wake() else blankScreen() end
                end
                lastRs = v
            end
        end
    end
end