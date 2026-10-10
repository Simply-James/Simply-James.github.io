-- /startup.lua
-- SimplyOS boot entry. Runs the kernel with crash recovery.
local STATE = "/os/data/system/boot.lua"

local function now() return math.floor(os.epoch("utc") / 1000) end

local function loadState()
    local ok, t = pcall(function()
        if not fs.exists(STATE) then return nil end
        local f = fs.open(STATE, "r")
        local s = f.readAll()
        f.close()
        return textutils.unserialize(s)
    end)
    if ok and type(t) == "table" then return t end
    return {}
end

local function saveState(t)
    pcall(function()
        fs.makeDir("/os/data/system")
        local f = fs.open(STATE, "w")
        f.write(textutils.serialize(t))
        f.close()
    end)
end

local function log(msg)
    pcall(function()
        fs.makeDir("/os/logs")
        local p = "/os/logs/system.txt"
        if fs.exists(p) and fs.getSize(p) > 16000 then
            if fs.exists("/os/logs/system.1.txt") then fs.delete("/os/logs/system.1.txt") end
            fs.move(p, "/os/logs/system.1.txt")
        end
        local f = fs.open(p, "a")
        f.write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f.close()
    end)
end

local state = loadState()
state.boots = (state.boots or 0) + 1
saveState(state)

while true do
    local ok, res = pcall(function()
        local k = dofile("/os/kernel/boot.lua")
        return k.run()
    end)

    if ok and res == "reboot" then os.reboot() return end
    if ok and res == "shutdown" then os.shutdown() return end
    -- developer escape: press Ctrl+T three times quickly, drops to the CraftOS shell
    if ok and res == "exit" then return end

    log(ok and ("kernel returned " .. tostring(res)) or ("kernel crash: " .. tostring(res)))

    local t = now()
    local recent = {}
    for _, v in ipairs(state.crashes or {}) do
        if t - v < 60 then recent[#recent + 1] = v end
    end
    recent[#recent + 1] = t
    state.crashes = recent
    saveState(state)

    if #recent >= 3 then
        local okc, action = pcall(function()
            return dofile("/os/kernel/crash.lua").recovery(tostring(res))
        end)
        if okc and action == "reset" then
            pcall(function() dofile("/os/kernel/crash.lua").factoryReset() end)
            os.reboot()
            return
        end
        if not okc then
            log("recovery screen failed: " .. tostring(action))
            print("SimplyOS crashed 3 times: " .. tostring(res))
            sleep(10)
        end
        state.crashes = {}
        saveState(state)
    else
        sleep(2)
    end
end
