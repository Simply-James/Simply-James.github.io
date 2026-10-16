-- /os/engine/net.lua
-- rednet wrapper for games: envelope {v=1, t=type, seq=n, d=payload}, heartbeat, reconnect token.
local N = {}
local HEARTBEAT, DEAD = 5, 16

local function openModem()
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" then
            local ok, w = pcall(peripheral.call, n, "isWireless")
            if ok and w then
                if not rednet.isOpen(n) then pcall(rednet.open, n) end
                return n
            end
        end
    end
end

-- server: s = N.server{protocol=, name=}
function N.server(opts)
    openModem()
    pcall(rednet.host, opts.protocol, opts.name or opts.protocol)
    local s = { handlers = {}, clients = {}, seq = 0 }
    function s.on(t, fn) s.handlers[t] = fn end
    function s.send(client, t, d)
        s.seq = s.seq + 1
        pcall(rednet.send, client, { v = 1, t = t, seq = s.seq, d = d }, opts.protocol)
    end
    function s.broadcast(t, d)
        for id in pairs(s.clients) do s.send(id, t, d) end
    end
    -- call from your event loop with every event
    function s.event(ev)
        if ev[1] == "rednet_message" and ev[4] == opts.protocol and type(ev[3]) == "table" and ev[3].v == 1 then
            local id, m = ev[2], ev[3]
            local c = s.clients[id]
            if not c then c = { id = id }; s.clients[id] = c end
            c.last = os.clock()
            if m.t == "hb" then s.send(id, "hb", {}) return end
            if s.handlers[m.t] then s.handlers[m.t](id, m.d) end
        end
        for id, c in pairs(s.clients) do
            if os.clock() - c.last > DEAD then
                s.clients[id] = nil
                if s.handlers.leave then s.handlers.leave(id) end
            end
        end
    end
    return s
end

-- client: c = N.connect{protocol=, server=name}
function N.connect(opts)
    openModem()
    local c = { handlers = {}, seq = 0, last = os.clock(), lastHb = 0, connected = false }
    function c.on(t, fn) c.handlers[t] = fn end
    local function lookup()
        local ok, id = pcall(rednet.lookup, opts.protocol, opts.server)
        if ok and id then c.serverId = id end
        if not c.serverId then
            local ok2, id2 = pcall(rednet.lookup, opts.protocol)
            if ok2 and id2 then c.serverId = id2 end
        end
        return c.serverId
    end
    function c.send(t, d)
        if not c.serverId and not lookup() then return false end
        c.seq = c.seq + 1
        pcall(rednet.send, c.serverId, { v = 1, t = t, seq = c.seq, d = d }, opts.protocol)
        return true
    end
    function c.event(ev)
        if ev[1] == "rednet_message" and ev[4] == opts.protocol and ev[2] == c.serverId
            and type(ev[3]) == "table" and ev[3].v == 1 then
            c.last = os.clock()
            if not c.connected then c.connected = true; if c.handlers.connect then c.handlers.connect() end end
            if ev[3].t ~= "hb" and c.handlers[ev[3].t] then c.handlers[ev[3].t](ev[3].d) end
        end
    end
    function c.update()
        local now = os.clock()
        if now - c.lastHb > HEARTBEAT then c.lastHb = now; c.send("hb", {}) end
        if c.connected and now - c.last > DEAD then
            c.connected = false
            c.serverId = nil
            if c.handlers.disconnect then c.handlers.disconnect() end
        end
    end
    return c
end

return N
