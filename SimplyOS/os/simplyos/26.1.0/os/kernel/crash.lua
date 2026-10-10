-- /os/kernel/crash.lua
-- Recovery screen and factory reset. Independent of the rest of the OS.
local M = {}

local function wrap(text, n, maxLines)
    local lines = {}
    text = tostring(text):gsub("[\r\n]+", " ")
    while #text > 0 and #lines < maxLines do
        lines[#lines + 1] = text:sub(1, n)
        text = text:sub(n + 1)
    end
    return lines
end

-- returns "retry" (tap) or "reset" (hold 3 s)
function M.recovery(msg)
    local gpu = peripheral.find("tm_gpu")
    if not gpu then
        print("SimplyOS recovery: " .. tostring(msg))
        sleep(10)
        return "retry"
    end
    for _, s in ipairs({ 128, 64, 32, 16 }) do
        if pcall(gpu.setSize, s) then break end
    end
    local W, H = 320, 512
    pcall(gpu.refreshSize)
    local ok, w, h = pcall(gpu.getSize)
    if ok and w and w > 0 then W, H = w, h end

    local okf, font = pcall(dofile, "/os/lib/font.lua")
    if okf and font then pcall(font.init, gpu) else font = nil end

    pcall(gpu.filledRectangle, 1, 1, W, H, 0xFF000000)
    local lines = {
        { "SimplyOS recovery", "normal", 0xFFFFFFFF },
        { "Crashed 3 times in a minute.", "small", 0xFF9A9AA6 },
    }
    for _, l in ipairs(wrap(msg, math.max(10, math.floor(W / 6) - 2), 8)) do
        lines[#lines + 1] = { l, "small", 0xFFEDEDF2 }
    end
    lines[#lines + 1] = { "", "small", 0xFF000000 }
    lines[#lines + 1] = { "Tap: try again", "normal", 0xFF6A8CFF }
    lines[#lines + 1] = { "Hold 3 s: factory reset", "normal", 0xFFFF6A6A }
    if font then
        local y = 24
        for _, l in ipairs(lines) do
            if l[1] ~= "" then font.draw(12, y, font.fit(l[1], W - 24, l[2]), l[3], 0xFF000000, l[2], 1) end
            y = y + font.height(l[2], 1) + 6
        end
    else
        print("SimplyOS recovery: " .. tostring(msg))
    end
    pcall(gpu.sync)

    local pressStart, lastTouch = nil, 0
    local timer = os.startTimer(0.2)
    while true do
        local ev, a = os.pullEventRaw()
        local now = os.clock()
        if ev == "tm_monitor_touch" then
            if not pressStart or now - lastTouch > 0.6 then pressStart = now end
            lastTouch = now
            if now - pressStart >= 3 then return "reset" end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(0.2)
            if pressStart and now - lastTouch > 0.6 then return "retry" end
        end
    end
end

-- wipes data, settings, notifications, user apps. keeps the OS, bundled apps, dev apps and the SIM.
function M.factoryReset()
    if fs.isDir("/os/data") then
        for _, name in ipairs(fs.list("/os/data")) do pcall(fs.delete, "/os/data/" .. name) end
    end
    pcall(fs.delete, "/os/settings.lua")
    pcall(fs.delete, "/os/settings.lua.tmp")
    if fs.isDir("/os/apps") then
        for _, id in ipairs(fs.list("/os/apps")) do
            local dir = "/os/apps/" .. id
            local keep = true
            pcall(function()
                local fn = loadfile(dir .. "/metadata.lua", "t", {})
                if fn then
                    local meta = fn()
                    if type(meta) == "table" and meta.system ~= true and meta.dev ~= true then keep = false end
                end
            end)
            if not keep then pcall(fs.delete, dir) end
        end
    end
end

return M
