-- /os/kernel/sched.lua
-- Cooperative scheduler. Tasks are coroutines. The kernel owns the one pullEventRaw loop.
-- S.spawn(name, fn, {kind=, onExit=function(task, err) end})  S.kill(task, err)
-- S.run{route=fn(ev)->consumed, onTerminate=fn}  S.stop(reason)  S.list()  S.current()
local S = {}

local tasks = {}
local nextId = 1
local current = nil
local timerOwner = {}
local stopReason = nil

-- timers go to the task that started them
local rawStart = os.__rawStartTimer or os.startTimer
os.__rawStartTimer = rawStart
os.startTimer = function(t)
    local id = rawStart(t)
    if current then timerOwner[id] = current end
    return id
end

local function finish(t, err)
    if not t.alive then return end
    t.alive = false
    for i, x in ipairs(tasks) do
        if x == t then table.remove(tasks, i) break end
    end
    if t.onExit then pcall(t.onExit, t, err) end
end

local function trace(co, err)
    local ok, tb = pcall(function() return debug and debug.traceback and debug.traceback(co) end)
    if ok and type(tb) == "string" then return tostring(err) .. "\n" .. tb end
    return tostring(err)
end

local function step(t, ...)
    if not t.alive or coroutine.status(t.co) ~= "suspended" then return end
    local prev = current
    current = t
    local res = table.pack(coroutine.resume(t.co, ...))
    current = prev
    if not res[1] then
        finish(t, trace(t.co, res[2]))
        return
    end
    if coroutine.status(t.co) == "dead" then
        finish(t, nil)
        return
    end
    t.filter = res[2]
end

function S.spawn(name, fn, opts)
    opts = opts or {}
    local t = {
        id = nextId, name = name, co = coroutine.create(fn), filter = nil,
        alive = true, kind = opts.kind or "service", onExit = opts.onExit,
    }
    nextId = nextId + 1
    tasks[#tasks + 1] = t
    step(t)
    return t
end

function S.kill(t, err) if t then finish(t, err) end end

function S.list()
    local out = {}
    for i, t in ipairs(tasks) do out[i] = t end
    return out
end

function S.current() return current end

local function dispatch(ev)
    if ev[1] == "timer" then
        local owner = timerOwner[ev[2]]
        if owner then
            timerOwner[ev[2]] = nil
            if owner.alive and (owner.filter == nil or owner.filter == "timer") then
                step(owner, table.unpack(ev, 1, ev.n))
            end
            return
        end
    end
    local snap = {}
    for i, t in ipairs(tasks) do snap[i] = t end
    for _, t in ipairs(snap) do
        if t.alive and (t.filter == nil or t.filter == ev[1]) then
            step(t, table.unpack(ev, 1, ev.n))
        end
    end
end

function S.stop(reason) stopReason = reason or "stop" end

function S.run(opts)
    opts = opts or {}
    while not stopReason do
        local ev = table.pack(os.pullEventRaw())
        if ev[1] == "terminate" then
            if opts.onTerminate then pcall(opts.onTerminate) end
        else
            local consumed = false
            if opts.route then
                local ok, r = pcall(opts.route, ev)
                consumed = ok and r
            end
            if not consumed then dispatch(ev) end
        end
    end
    return stopReason
end

return S
