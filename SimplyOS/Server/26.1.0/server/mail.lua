-- /server/mail.lua
-- Store and forward (ROOT_SERVER_DEVDOC 5.2). The server holds a message only until the receiving
-- phone confirms it wrote it to disk. Mailboxes live on the storage volumes: mail/<number>.lua.
-- Sender notices (delivered / expired) for a phone that is offline wait in notify/<number>.lua
-- and are sent on its next login or msg.sync, then removed.
-- Additions to the doc's protocol: msg.received is answered with msg.received.ok {from,id},
-- msg.sync with msg.sync.ok {pending}.
-- Bodies: sealed (cipher.lua) with the session key in transit (enc = 1 in the payload) and sealed
-- with a server storage key at rest (field eb). Plain bodies are refused while net.requireEncryption is on.
return function(S)
    local M = {}

    local function boxRel(n) return "mail/" .. n .. ".lua" end
    local function noteRel(n) return "notify/" .. n .. ".lua" end

    local function loadBox(number)
        local copies = S.storage.readAll(boxRel(number))
        local box = copies[1] or {msgs = {}}
        box.msgs = type(box.msgs) == "table" and box.msgs or {}
        if #copies > 1 then
            local seen = {}
            for _, m in ipairs(box.msgs) do
                seen[m.from .. "|" .. m.id] = true
            end
            for i = 2, #copies do
                for _, m in ipairs(copies[i].msgs or {}) do
                    local k = m.from .. "|" .. m.id
                    if not seen[k] then
                        seen[k] = true;
                        box.msgs[#box.msgs + 1] = m
                    end
                end
            end
            S.log.warn("mail", "merged duplicate mailbox copies for " .. number)
        end
        return box
    end

    local function saveBox(number, box)
        if #box.msgs == 0 then
            S.storage.delete(boxRel(number))
            return true
        end
        return S.storage.write(boxRel(number), box)
    end

    local function boxBytes(box)
        local n = 0
        for _, m in ipairs(box.msgs) do
            n = n + #(m.eb or m.body or "") + #m.id + #m.from + 60
        end
        return n
    end

    -- plain text of a stored message (also reads old unsealed ones)
    local function plainBody(m)
        if m.eb then
            return S.cipher.open(S.subscribers.storageKey(), m.eb)
        end
        return m.body
    end

    -- push one stored message to a logged-in phone, sealed with its session key
    local function sendDeliver(number, m)
        local sess = S.auth.sessionFor(number)
        if not sess then return false end
        local body = plainBody(m)
        if not body then
            S.log.warn("mail",
                       "cannot read stored body of " .. m.from .. " " .. m.id)
            return false
        end
        S.net.send(sess.id, "msg.deliver", nil, {
            from = m.from,
            id = m.id,
            body = S.cipher.seal(sess.enc, body),
            enc = 1,
            ts = m.ts,
            sts = m.sts
        })
        return true
    end

    local function sorted(box)
        table.sort(box.msgs, function(a, b)
            if a.sts ~= b.sts then return a.sts < b.sts end
            return a.id < b.id
        end)
        return box.msgs
    end

    -- sender notices -------------------------------------------------------
    local function sendNotice(to, id, status)
        local t = status == "delivered" and "msg.delivered" or "msg.expired"
        return S.net.sendNumber(to, t, {id = id})
    end

    local function addNotice(to, id, status)
        if sendNotice(to, id, status) then return end
        local n = S.storage.read(noteRel(to), {items = {}})
        n.items = n.items or {}
        n.items[#n.items + 1] = {id = id, status = status, ts = S.util.now()}
        while #n.items > 200 do table.remove(n.items, 1) end
        S.storage.write(noteRel(to), n)
    end

    local function flushNotices(number)
        local n = S.storage.read(noteRel(number), nil)
        if not n then return end
        for _, it in ipairs(n.items or {}) do
            sendNotice(number, it.id, it.status)
        end
        S.storage.delete(noteRel(number))
    end

    -- delivery -------------------------------------------------------------
    local function pushPending(number)
        local box = loadBox(number)
        for _, m in ipairs(sorted(box)) do sendDeliver(number, m) end
        return #box.msgs
    end

    function M.onLogin(number)
        pushPending(number)
        flushNotices(number)
    end

    -- handlers -------------------------------------------------------------
    S.net.on("msg.send", function(id, msg, d, s)
        local to, mid, body = d.to, d.id, d.body
        if type(mid) ~= "string" or #mid == 0 or #mid > 40 or type(body) ~=
            "string" then
            S.net.err(id, msg, "unknown", "bad message")
            return
        end
        if d.enc == 1 then
            body = S.cipher.open(s.enc, body)
            if not body then
                S.net.err(id, msg, "unknown", "bad ciphertext")
                return
            end
        elseif S.config.get("net.requireEncryption") then
            S.net.err(id, msg, "unknown", "encryption required")
            return
        end
        local function fail(reason)
            S.net.send(id, "msg.fail", msg.rid, {id = mid, reason = reason})
        end
        if #body > 200 then
            fail("toolong")
            return
        end
        local rec = S.subscribers.valid(to) and S.subscribers.get(to)
        if not rec or rec.status == "revoked" then
            fail("unknown")
            return
        end

        local box = loadBox(to)
        for _, m in ipairs(box.msgs) do
            if m.from == s.number and m.id == mid then
                S.net.send(id, "msg.ack", msg.rid, {id = mid}) -- already stored: idempotent
                return
            end
        end
        if #box.msgs >= S.config.get("mail.maxPerBox") or boxBytes(box) + #body +
            60 > S.config.get("mail.maxBytesPerBox") then
            fail("full")
            return
        end
        box.msgs[#box.msgs + 1] = {
            from = s.number,
            id = mid,
            eb = S.cipher.seal(S.subscribers.storageKey(), body),
            ts = type(d.ts) == "number" and d.ts or S.util.now(),
            sts = S.util.now()
        }
        local ok, why = saveBox(to, box)
        if not ok then
            S.log.warn("mail",
                       "store failed for " .. to .. ": " .. tostring(why))
            fail("full")
            return
        end
        S.net.send(id, "msg.ack", msg.rid, {id = mid}) -- only after it is stored
        sendDeliver(to, box.msgs[#box.msgs])
    end, {session = true})

    S.net.on("msg.received", function(id, msg, d, s)
        local from, mid = d.from, d.id
        local box = loadBox(s.number)
        local found
        for i, m in ipairs(box.msgs) do
            if m.from == from and m.id == mid then
                found = i
                break
            end
        end
        if found then
            table.remove(box.msgs, found)
            saveBox(s.number, box)
            addNotice(from, mid, "delivered")
        end
        S.net.send(id, "msg.received.ok", msg.rid, {from = from, id = mid})
    end, {session = true})

    S.net.on("msg.sync", function(id, msg, d, s)
        local n = pushPending(s.number)
        flushNotices(s.number)
        S.net.send(id, "msg.sync.ok", msg.rid, {pending = n})
    end, {session = true})

    S.net.on("who", function(id, msg, d)
        local rec = S.subscribers.valid(d.number) and
                        S.subscribers.get(d.number)
        S.net.send(id, "who.reply", msg.rid,
                   {exists = rec ~= nil and rec.status ~= "revoked"})
    end, {session = true})

    -- housekeeping ---------------------------------------------------------
    local function numberOf(file) return (file:gsub("%.lua$", "")) end

    -- removes messages older than the TTL and tells their senders. returns how many
    function M.sweep()
        local ttl = S.config.get("mail.ttlDays") * 86400
        local now, removed = S.util.now(), 0
        for _, file in ipairs(S.storage.list("mail")) do
            local number = numberOf(file)
            local box = loadBox(number)
            local keep = {}
            for _, m in ipairs(box.msgs) do
                if m.sts + ttl < now then
                    removed = removed + 1
                    addNotice(m.from, m.id, "expired")
                else
                    keep[#keep + 1] = m
                end
            end
            if #keep ~= #box.msgs then
                box.msgs = keep;
                saveBox(number, box)
            end
        end
        if removed > 0 then
            S.log.info("mail", "expired " .. removed .. " messages")
        end
        return removed
    end

    -- per mailbox counts: { {number, count, bytes}, ... } and the total
    function M.queues()
        local out, total = {}, 0
        for _, file in ipairs(S.storage.list("mail")) do
            local number = numberOf(file)
            local box = loadBox(number)
            if #box.msgs > 0 then
                out[#out + 1] = {
                    number = number,
                    count = #box.msgs,
                    bytes = boxBytes(box)
                }
                total = total + #box.msgs
            end
        end
        return out, total
    end

    function M.purge(number)
        local box = loadBox(number)
        local n = #box.msgs
        S.storage.delete(boxRel(number))
        return n
    end

    return M
end
