-- /server/net.lua
-- Wireless modem, rednet host, request routing. Envelope: {v=1, t=type, rid=, tok=, seq=, d={}}
-- Two tasks: rx (only collects packets, never blocks) and run (handles them from a queue),
-- so no packet is lost while a handler is busy.
return function(S)
    local M = {
        ready = false,
        modem = nil,
        peers = {},
        handlers = {},
        rx = 0,
        tx = 0,
        bad = 0
    }
    local rate, queue = {}, {}

    local function proto() return S.config.get("net.protocol") end

    -- opts.session = true: the packet must carry a valid tok and increasing seq.
    -- opts.admin = true: also requires the subscriber to be an admin (and admin.remote on).
    -- fn(computerId, packet, payload, session)
    function M.on(t, fn, opts)
        M.handlers[t] = {
            fn = fn,
            session = (opts and (opts.session or opts.admin)) or false,
            admin = opts and opts.admin or false
        }
    end

    function M.send(id, t, rid, d)
        M.tx = M.tx + 1
        return rednet.send(id, {v = 1, t = t, rid = rid, d = d or {}}, proto())
    end

    function M.err(id, msg, code, text)
        M.send(id, "err", msg and msg.rid, {code = code, text = text})
    end

    -- push to a logged-in phone by number; false if it is not logged in
    function M.sendNumber(number, t, d)
        local s = S.auth and S.auth.sessionFor(number)
        if not s then return false end
        M.send(s.id, t, nil, d)
        return true
    end

    local function findModem()
        for _, name in ipairs(peripheral.getNames()) do
            local ok, isModem = pcall(peripheral.hasType, name, "modem")
            if ok and isModem then
                local ok2, wireless = pcall(peripheral.call, name, "isWireless")
                if ok2 and wireless then return name end
            end
        end
    end

    function M.open()
        local name = findModem()
        if not name then
            if M.ready then S.log.warn("net", "wireless modem lost") end
            M.ready, M.modem = false, nil
            return false
        end
        if M.ready and M.modem == name and rednet.isOpen(name) then
            return true
        end
        local host = S.config.get("server.hostname")
        if host == "localhost" then host = "root" end
        if not rednet.isOpen(name) then rednet.open(name) end
        rednet.host(proto(), host)
        S.log
            .info("net", "hosting " .. proto() .. "/" .. host .. " on " .. name)
        M.ready, M.modem = true, name
        return true
    end

    function M.stop()
        pcall(rednet.unhost, proto())
        if M.modem then pcall(rednet.close, M.modem) end
        M.ready = false
    end

    local function handle(id, msg)
        if type(msg) ~= "table" then
            M.bad = M.bad + 1
            return
        end
        M.rx = M.rx + 1
        if msg.v ~= 1 or type(msg.t) ~= "string" then
            M.bad = M.bad + 1
            M.err(id, msg, "unknown", "bad envelope")
            return
        end

        local now = S.util.now()
        local peer = M.peers[id]
        if not peer then
            peer = {first = now, last = now, count = 0, number = nil}
            M.peers[id] = peer
            S.log.info("net", "new computer id " .. id)
        end
        peer.last = now
        peer.count = peer.count + 1

        local limit = S.config.get("net.rateLimit")
        local r = rate[id]
        if not r or r.sec ~= now then
            r = {sec = now, n = 0};
            rate[id] = r
        end
        r.n = r.n + 1
        if r.n > limit then
            if r.n == limit + 1 then
                M.err(id, msg, "busy", "slow down")
            end
            return
        end

        local h = M.handlers[msg.t]
        if not h then
            M.err(id, msg, "unknown", "unknown type")
            return
        end

        local session
        if h.session then
            local code
            session, code = S.auth.check(id, msg)
            if not session then
                M.err(id, msg, code or "session", "login required")
                return
            end
            peer.number = session.number
            if h.admin and
                not (S.config.get("admin.remote") and
                    S.subscribers.isAdmin(session.number)) then
                S.log.warn("net",
                           "admin request " .. msg.t .. " refused for " ..
                               session.number)
                M.err(id, msg, "auth", "not an admin")
                return
            end
        end

        local ok, e = pcall(h.fn, id, msg,
                            type(msg.d) == "table" and msg.d or {}, session)
        if not ok then
            S.log
                .error("net", "handler " .. msg.t .. " failed: " .. tostring(e))
            M.err(id, msg, "unknown", "server error")
        end
    end

    -- ping: with a tok it is checked as a session packet; without one only if allowed by config
    M.on("ping", function(id, msg)
        if msg.tok ~= nil then
            local s, code = S.auth.check(id, msg)
            if not s then
                M.err(id, msg, code or "session", "login required")
                return
            end
            local peer = M.peers[id]
            if peer then peer.number = s.number end
        elseif not S.config.get("net.allowAnonPing") then
            M.err(id, msg, "session", "login required")
            return
        end
        M.send(id, "pong", msg.rid, {serverTime = S.util.now()})
    end)

    -- task: collect packets and watch the modem
    function M.rx_task()
        local timer
        while true do
            if not M.ready then
                M.open()
                if not M.ready and not timer then
                    timer = os.startTimer(10)
                end
            end
            local ev, a, b, c = os.pullEvent()
            if ev == "rednet_message" and c == proto() and M.ready then
                queue[#queue + 1] = {id = a, msg = b}
                if #queue > 200 then table.remove(queue, 1) end
                os.queueEvent("srv_pkt")
            elseif ev == "timer" and a == timer then
                timer = nil
            elseif ev == "peripheral" or ev == "peripheral_detach" then
                M.open()
            end
        end
    end

    -- task: handle queued packets
    function M.run()
        while true do
            while #queue > 0 do
                local p = table.remove(queue, 1)
                handle(p.id, p.msg)
            end
            os.pullEvent("srv_pkt")
        end
    end

    function M.status()
        local list = {}
        for id, p in pairs(M.peers) do
            list[#list + 1] = {
                id = id,
                last = p.last,
                count = p.count,
                number = p.number
            }
        end
        table.sort(list, function(a, b) return a.last > b.last end)
        return {
            ready = M.ready,
            modem = M.modem,
            rx = M.rx,
            tx = M.tx,
            bad = M.bad,
            peers = list
        }
    end

    return M
end
