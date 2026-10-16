-- /os/kernel/netsvc.lua
-- Network service: modem, root server lookup, SIM login, keepalive, signal, message daemon.
-- N.start(ctx)  N.request(type, data, timeout) -> reply table or nil, err   N.state()  N.send(type, data)
local N = {}
local crypto = dofile("/os/lib/crypto.lua")
local cipher = dofile("/os/lib/cipher.lua")
local simlib = dofile("/os/lib/sim.lua")
local messages = dofile("/os/lib/messages.lua")
local fsutil = dofile("/os/lib/fsutil.lua")
local settings = dofile("/os/lib/settings.lua")
local appslib = dofile("/os/lib/apps.lua")

local PROTO = "simplyos"
local st = { status = "starting", serverId = nil, sess = nil, lastPong = -1000, rtt = nil, dist = nil,
    modem = nil, lastErr = nil, fails = 0, lookupAt = -1000, loginAt = -1000, pingAt = 0, outAt = 0, simNumber = nil }
local ridCounter = math.random(1000, 99999)
local ctx
local lastStatusKey = ""

local cOpen = cipher.open or cipher.unseal or cipher.decrypt
local cSeal = cipher.seal or cipher.encrypt

local function slog(t) if ctx then ctx.log("net: " .. tostring(t)) end end

local function status(s)
    st.status = s
end

local function announce()
    local key = st.status .. ":" .. tostring(N.bars())
    if key ~= lastStatusKey then
        lastStatusKey = key
        os.queueEvent("simplyos_status")
    end
end

function N.bars()
    if not st.sess or os.clock() - st.lastPong > 20 then return 0 end
    local rtt = st.rtt or 1
    local b = rtt < 0.15 and 4 or rtt < 0.4 and 3 or rtt < 1 and 2 or 1
    local maxr = settings.get("net.maxRange")
    if maxr > 0 and st.dist then
        local f = 1 - st.dist / maxr
        local db = f > 0.75 and 4 or f > 0.5 and 3 or f > 0.25 and 2 or 1
        b = math.min(b, db)
    end
    return b
end

function N.state()
    return {
        status = st.status, bars = N.bars(), number = st.simNumber, online = st.sess ~= nil,
        admin = st.sess and st.sess.admin or false, serverId = st.serverId, lastErr = st.lastErr,
        dist = st.dist, rtt = st.rtt,
    }
end

local function findModem()
    for _, n in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(n)
        if t == "modem" then
            local ok, w = pcall(peripheral.call, n, "isWireless")
            if ok and w then return n end
        end
    end
end

local function observe(ev)
    if ev[1] == "modem_message" and st.serverId and ev[4] == st.serverId and type(ev[5]) == "table"
        and ev[5].sProtocol == PROTO then
        st.dist = ev[6]
    end
end

local function isServerMsg(ev)
    return ev[1] == "rednet_message" and ev[2] == st.serverId and ev[4] == PROTO
        and type(ev[3]) == "table" and ev[3].v == 1
end

local function build(t, d, rid)
    local p = { v = 1, t = t, rid = rid, d = d or {} }
    if st.sess then
        st.sess.seq = st.sess.seq + 1
        p.tok, p.seq = st.sess.tok, st.sess.seq
    else
        p.seq = 0
    end
    return p
end

-- ---------- incoming pushes ----------
local function seenPush(id)
    local t = fsutil.readTable("/os/data/system/pushseen.lua") or { ids = {} }
    for _, v in ipairs(t.ids) do if v == id then return true end end
    t.ids[#t.ids + 1] = id
    while #t.ids > 100 do table.remove(t.ids, 1) end
    fsutil.writeTable("/os/data/system/pushseen.lua", t)
    return false
end

local function fire(t, d)
    if not st.serverId then return end
    ridCounter = ridCounter + 1
    pcall(rednet.send, st.serverId, build(t, d, ridCounter), PROTO)
end
N.send = fire

local function onDeliver(d)
    if type(d) ~= "table" or not d.from or not d.id then return end
    local body = d.body
    if d.enc then
        if not (st.sess and st.sess.enc and cOpen) then return end
        local plain, why = cOpen(st.sess.enc, d.body)
        if not plain then
            st.lastErr = "decrypt failed: " .. tostring(why)
            slog(st.lastErr)
            return
        end
        body = plain
    end
    local r = messages.addIncoming(d.from, d.id, tostring(body), d.ts, d.sts)
    if r then
        fire("msg.received", { from = d.from, id = d.id })
        if r == "new" and ctx then
            ctx.notify{ appId = "messages", title = messages.nameOf(d.from), text = tostring(body) }
        end
    end
end

local function handlePush(m)
    local t, d = m.t, m.d or {}
    if t == "msg.deliver" then onDeliver(d)
    elseif t == "msg.delivered" then messages.setStatus(d.id, "delivered")
    elseif t == "msg.expired" then messages.setStatus(d.id, "failed")
    elseif t == "notify.push" then
        if not d.id or seenPush(d.id) then return end
        if settings.get("notify.server") and ctx then
            local app = d.appId and appslib.find(d.appId)
            ctx.notify{ appId = d.appId or "system", appName = app and app.name or "System", title = d.title, text = d.text }
        end
    end
end

-- ---------- request / reply ----------
function N.request(t, d, timeout)
    if not st.serverId then return nil, "no server" end
    timeout = timeout or 8
    ridCounter = ridCounter + 1
    local rid = ridCounter
    local deadline = os.clock() + timeout
    local backoff = { 1, 2, 4, 8 }
    local attempt = 0
    local stash = {}
    local result, why
    while not result and os.clock() < deadline do
        attempt = attempt + 1
        pcall(rednet.send, st.serverId, build(t, d, rid), PROTO)
        local wait = math.min(backoff[math.min(attempt, 4)], math.max(0.05, deadline - os.clock()))
        local tid = os.startTimer(wait)
        while true do
            local ev = table.pack(os.pullEvent())
            observe(ev)
            if ev[1] == "timer" then
                if ev[2] == tid then break end
                stash[#stash + 1] = ev
            elseif isServerMsg(ev) then
                local m = ev[3]
                if m.rid == rid then result = m; break end
                handlePush(m)
            elseif ev[1] == "simplyos_back" or ev[1] == "simplyos_exit" or ev[1] == "simplyos_relayout"
                or ev[1] == "simplyos_redraw" then
                stash[#stash + 1] = ev
            end
        end
        pcall(os.cancelTimer, tid)
    end
    for _, ev in ipairs(stash) do os.queueEvent(table.unpack(ev, 1, ev.n)) end
    if not result then return nil, "timeout" end
    if result.t == "err" and type(result.d) == "table" and (result.d.code == "session" or result.d.code == "auth") then
        st.sess = nil
    end
    return result
end

-- ---------- session ----------
local function login(sim)
    st.loginAt = os.clock()
    status("login")
    local r = N.request("hello", { number = sim.number, imsi = sim.imsi }, 8)
    if not r then st.lastErr = "no answer to hello"; st.fails = st.fails + 1; if st.fails >= 3 then st.serverId = nil end return false end
    if r.t == "err" then st.lastErr = "hello: " .. tostring(r.d and (r.d.text or r.d.code)); return false end
    if r.t ~= "challenge" or type(r.d) ~= "table" or not r.d.nonce then st.lastErr = "bad challenge" return false end
    local nonce = r.d.nonce
    local mac = crypto.hmac(sim.key, nonce .. sim.number)
    local r2 = N.request("auth", { mac = mac }, 8)
    if not r2 then st.lastErr = "no answer to auth" return false end
    if r2.t ~= "session" or type(r2.d) ~= "table" then
        st.lastErr = "auth: " .. tostring(r2.d and (r2.d.text or r2.d.code) or r2.t)
        return false
    end
    st.sess = { tok = r2.d.tok, seq = 0, admin = r2.d.admin == true, started = os.clock(),
        enc = crypto.hmac(sim.key, "enc|" .. nonce .. sim.number) }
    st.fails = 0
    st.lastErr = nil
    st.lastPong = os.clock()
    st.pingAt = os.clock()
    status("online")
    slog("logged in as " .. sim.number)
    N.request("msg.sync", {}, 8)
    return true
end

local function ping()
    st.pingAt = os.clock()
    local t0 = os.clock()
    local r = N.request("ping", {}, 6)
    if r and r.t == "pong" then
        st.rtt = os.clock() - t0
        st.lastPong = os.clock()
        st.fails = 0
    else
        st.fails = st.fails + 1
        if st.fails >= 3 then
            st.sess = nil
            st.serverId = nil
            status("searching")
        end
    end
end

local function processOutbox()
    st.outAt = os.clock()
    for _, o in ipairs(messages.outbox()) do
        if not st.sess then return end
        local t = messages.thread(o.to)
        local m
        for _, x in ipairs(t.msgs) do if x.id == o.id then m = x end end
        if not m then
            messages.setStatus(o.id, "failed")
        elseif m.status == "sending" then
            local d = { to = o.to, id = o.id, ts = m.ts }
            if cSeal and st.sess.enc then d.body = cSeal(st.sess.enc, m.body); d.enc = 1 else d.body = m.body end
            local r = N.request("msg.send", d, 10)
            if r and r.t == "msg.ack" then messages.setStatus(o.id, "sent")
            elseif r and r.t == "msg.fail" then
                messages.setStatus(o.id, "failed")
            elseif r and r.t == "err" then
                st.lastErr = "send: " .. tostring(r.d and (r.d.text or r.d.code))
                if r.d and (r.d.code == "unknown" or r.d.code == "toolong" or r.d.code == "full") then messages.setStatus(o.id, "failed") end
            end
        end
    end
end

local function tick()
    if not st.modem then
        st.modem = findModem()
        if st.modem and not rednet.isOpen(st.modem) then pcall(rednet.open, st.modem) end
    end
    if not st.modem then status("nomodem") return end
    local sim = simlib.read()
    if not sim then
        if st.sess then st.sess = nil end
        st.simNumber = nil
        status("nosim")
        return
    end
    if st.simNumber ~= sim.number then st.sess = nil; st.simNumber = sim.number end
    local now = os.clock()
    if not st.serverId then
        if now - st.lookupAt > 30 or st.lookupAt < 0 then
            st.lookupAt = now
            local ok, id = pcall(rednet.lookup, PROTO, sim.server or "root")
            if ok and id then st.serverId = id end
        end
        if not st.serverId then status("searching") return end
    end
    if not st.sess then
        if now - st.loginAt > 10 then login(sim) end
        return
    end
    if now - st.sess.started > 23 * 3600 then st.sess = nil return end
    if now - st.pingAt >= 10 then ping() end
    if st.sess and now - st.outAt >= 3 then processOutbox() end
end

function N.start(c)
    ctx = c
    c.net = N
    c.sched.spawn("net", function()
        while true do
            local ok, err = pcall(tick)
            if not ok then st.lastErr = tostring(err); slog("tick error: " .. tostring(err)) end
            announce()
            local tid = os.startTimer(1)
            while true do
                local ev = table.pack(os.pullEvent())
                observe(ev)
                if ev[1] == "timer" and ev[2] == tid then break end
                if isServerMsg(ev) then handlePush(ev[3]) end
                if ev[1] == "simplyos_msg" then st.outAt = -100 end
            end
        end
    end, { kind = "service" })
end

return N
