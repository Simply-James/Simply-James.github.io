-- /os/kernel/services.lua
-- Kernel services. Build 26.1.0: watchdog feeder.
-- The feeder is its own task, so it keeps running while an app is in front.
local M = {}

function M.start(ctx)
    local sched, settings = ctx.sched, ctx.settings
    local wdt = peripheral.find("tm_wdt")
    ctx.wdt = wdt
    if not wdt then ctx.log("no watchdog peripheral") return end

    pcall(function()
        ctx.log("watchdog timeout=" .. tostring(wdt.getTimeout()) .. " enabled=" .. tostring(wdt.isEnabled()))
    end)

    sched.spawn("wdt", function()
        local ready = false
        local armed = false
        local deadline = os.clock() + 15
        local ticks = 0
        local want = settings.get("dev.watchdog")
        local timer = os.startTimer(1)
        while true do
            local ev, a = os.pullEvent()
            if ev == "simplyos_shell_ready" then ready = true end
            if ev == "timer" and a == timer then
                timer = os.startTimer(1)
                pcall(wdt.reset)
                ticks = ticks + 1
                if ticks % 5 == 0 then want = settings.get("dev.watchdog") end
                if want and not armed and (ready or os.clock() > deadline) then
                    pcall(wdt.setEnabled, true)
                    armed = true
                elseif not want and (armed or ticks == 1) then
                    pcall(wdt.setEnabled, false)
                    armed = false
                end
            end
        end
    end, { kind = "service" })
end

function M.stop(ctx)
    if ctx.wdt then pcall(ctx.wdt.setEnabled, false) end
end

return M
