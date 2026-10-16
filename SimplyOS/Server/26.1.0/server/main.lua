-- /server/main.lua
-- SimplyOS Root Server 26.4.0. Cooperative scheduler like OS_DEVDOC 4.2: tasks are coroutines,
-- this file owns the one os.pullEventRaw loop. Returns "quit" on a clean stop, errors otherwise.
local S = {version = "26.4.0", startMs = os.epoch("utc")}

local function mod(name)
    local fn, err = loadfile("/server/" .. name .. ".lua", "t", _ENV)
    if not fn then error("cannot load " .. name .. ": " .. tostring(err), 0) end
    return fn()(S)
end

S.util = mod("util")
S.store = mod("store")
S.config = mod("config")
S.config.load()
S.log = mod("log")
S.crypto = mod("crypto")
S.cipher = mod("cipher")
S.storage = mod("storage")
S.subscribers = mod("subscribers")
S.net = mod("net")
S.auth = mod("auth")
S.push = mod("push")
S.mail = mod("mail")
S.source = mod("source")
S.repo = mod("repo")
S.backup = mod("backup")
S.remote = mod("remote")
S.admin = mod("admin")

S.log.info("main", "starting " .. S.version)
S.crypto.init()
S.storage.scan()
S.subscribers.load()
S.repo.load()
S.repo.check()
S.backup.load()

-- scheduler
local tasks, stopping = {}, false
function S.stop() stopping = true end

local step

local function start(t)
    t.co = coroutine.create(t.fn)
    t.filter, t.restartTimer = nil, nil
    step(t)
end

step = function(t, ...)
    local ok, res = coroutine.resume(t.co, ...)
    if not ok then
        S.log.error("main", "task " .. t.name .. " crashed: " .. tostring(res))
        t.co = nil
        local now = S.util.now()
        local c = t.crashes
        c[#c + 1] = now
        while c[1] and now - c[1] > 60 do table.remove(c, 1) end
        if #c >= 5 then
            error("task " .. t.name .. " keeps crashing: " .. tostring(res), 0)
        end
        t.restartTimer = os.startTimer(2)
    elseif coroutine.status(t.co) == "dead" then
        t.co = nil
    else
        t.filter = res
    end
end

local function spawn(name, fn)
    tasks[#tasks + 1] = {name = name, fn = fn, crashes = {}}
end

spawn("net-rx", S.net.rx_task)
spawn("net", S.net.run)
spawn("storage", S.storage.run)
spawn("admin", S.admin.run)

-- housekeeping: flush lastSeen, drop expired sessions, expire old mail
spawn("housekeeping", function()
    local lastSweep = S.util.now()
    while true do
        sleep(30)
        S.subscribers.flush()
        S.auth.sweep()
        S.backup.tick()
        if S.util.now() - lastSweep >= S.config.get("mail.sweepMinutes") * 60 then
            lastSweep = S.util.now()
            S.mail.sweep()
            S.push.sweep()
        end
    end
end)

-- optional watchdog feeder (own task, never fed by the admin menu)
local wdt
spawn("wdt", function()
    while true do
        if S.config.get("wdt.enabled") then
            wdt = wdt or peripheral.find("tm_wdt")
            if wdt then
                pcall(wdt.setEnabled, true)
                pcall(wdt.reset)
            end
        end
        sleep(math.max(1, S.config.get("wdt.feedSeconds")))
    end
end)

local function cleanup()
    if wdt then pcall(wdt.setEnabled, false) end -- a clean stop must not reboot the computer
    pcall(S.subscribers.flush)
    S.net.stop()
    S.log.info("main", "stopped")
end

local ok, err = pcall(function()
    for _, t in ipairs(tasks) do start(t) end
    while not stopping do
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "terminate" then break end
        for _, t in ipairs(tasks) do
            if t.co then
                if t.filter == nil or t.filter == ev[1] then
                    step(t, table.unpack(ev, 1, ev.n))
                end
            elseif t.restartTimer and ev[1] == "timer" and ev[2] ==
                t.restartTimer then
                start(t)
            end
        end
    end
end)

cleanup()
if not ok then error(err, 0) end
return "quit"
