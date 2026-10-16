-- /server/push.lua
-- Server broadcast notifications. The server always sends; the phone decides whether to show it
-- (phone setting, default on). One global list with increasing ids; each subscriber remembers the
-- last id it was sent (pushSeen), so a phone that was offline gets what it missed on login.
-- Packet: notify.push {id, title, text, kind?, appId?, ts}. Phones dedupe by id.
return function(S)
    local M = {}
    local REL = "push/broadcast.lua"

    local function load() return S.storage.read(REL, {next = 1, items = {}}) end

    function M.latest()
        local d = load()
        return (d.next or 1) - 1
    end

    local function packet(it)
        return {
            id = it.id,
            title = it.title,
            text = it.text,
            kind = it.kind,
            appId = it.appId,
            ts = it.ts
        }
    end

    -- item: {title, text, kind?, appId?}. returns the id
    function M.broadcast(item)
        local d = load()
        d.items = d.items or {}
        local it = {
            id = d.next or 1,
            ts = S.util.now(),
            title = tostring(item.title or ""):sub(1, 60),
            text = tostring(item.text or ""):sub(1, 200),
            kind = item.kind,
            appId = item.appId
        }
        d.next = it.id + 1
        d.items[#d.items + 1] = it
        while #d.items > 50 do table.remove(d.items, 1) end
        S.storage.write(REL, d)
        local sent = 0
        for _, s in ipairs(S.auth.list()) do
            S.net.send(s.id, "notify.push", nil, packet(it))
            S.subscribers.setPushSeen(s.number, it.id)
            sent = sent + 1
        end
        S.log.info("push", "broadcast #" .. it.id .. " to " .. sent ..
                       " logged in phones")
        return it.id, sent
    end

    -- send what a phone has not been sent yet
    function M.onLogin(number)
        local rec = S.subscribers.get(number)
        if not rec then return end
        local d = load()
        local last = (d.next or 1) - 1
        if rec.pushSeen == nil then
            S.subscribers.setPushSeen(number, last) -- old record: do not replay the backlog
            return
        end
        local cutoff = S.util.now() - S.config.get("push.keepDays") * 86400
        for _, it in ipairs(d.items or {}) do
            if it.id > rec.pushSeen and it.ts >= cutoff then
                S.net.sendNumber(number, "notify.push", packet(it))
            end
        end
        S.subscribers.setPushSeen(number, last)
    end

    function M.sweep()
        local d = load()
        local cutoff = S.util.now() - S.config.get("push.keepDays") * 86400
        local keep = {}
        for _, it in ipairs(d.items or {}) do
            if it.ts >= cutoff then keep[#keep + 1] = it end
        end
        if #keep ~= #(d.items or {}) then
            d.items = keep;
            S.storage.write(REL, d)
        end
    end

    return M
end
