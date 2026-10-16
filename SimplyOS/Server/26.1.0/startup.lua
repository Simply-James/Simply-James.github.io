-- /startup.lua
-- SimplyOS Root Server boot entry. Runs /server/main.lua with crash recovery.
-- Crash: log, restart after 2 s. 5 crashes within 60 s: give up and show the error.
local MAIN = "/server/main.lua"
local CRASHLOG = "/server/logs/crash.log"

local function now() return math.floor(os.epoch("utc") / 1000) end

local function note(text)
    pcall(function()
        if not fs.exists("/server/logs") then fs.makeDir("/server/logs") end
        if fs.exists(CRASHLOG) and fs.getSize(CRASHLOG) > 16000 then fs.delete(CRASHLOG) end
        local f = fs.open(CRASHLOG, "a")
        if f then
            f.writeLine(os.date("!%Y-%m-%d %H:%M:%S") .. " " .. tostring(text))
            f.close()
        end
    end)
end

local crashes = {}

while true do
    local fn, err = loadfile(MAIN, "t", _ENV)
    local ok, res
    if fn then ok, res = pcall(fn) else ok, res = false, err end

    if ok then
        term.clear()
        term.setCursorPos(1, 1)
        print("Server stopped.")
        return
    end

    note(res)
    local t = now()
    crashes[#crashes + 1] = t
    while crashes[1] and t - crashes[1] > 60 do table.remove(crashes, 1) end

    term.clear()
    term.setCursorPos(1, 1)
    if #crashes >= 5 then
        if term.isColor and term.isColor() then term.setTextColor(colors.red) end
        print("Server crashed 5 times in 60 s. Giving up.")
        if term.isColor and term.isColor() then term.setTextColor(colors.white) end
        print(tostring(res))
        print("")
        print("Log: " .. CRASHLOG)
        return
    end
    print("Server crashed: " .. tostring(res))
    print("Restarting in 2 s...")
    sleep(2)
end
