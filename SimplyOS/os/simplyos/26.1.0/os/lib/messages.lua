-- /os/lib/messages.lua
-- Message store: /os/data/messages/<number>.lua per conversation, outbox.lua, contacts.lua, meta.lua
local fsutil = dofile("/os/lib/fsutil.lua")
local settings = dofile("/os/lib/settings.lua")
local M = {}
local DIR = "/os/data/messages/"

local function path(number) return DIR .. number .. ".lua" end
local function now() return math.floor(os.epoch("utc") / 1000) end

function M.thread(number)
    local t = fsutil.readTable(path(number))
    if type(t) ~= "table" or type(t.msgs) ~= "table" then t = { number = number, msgs = {}, unread = 0 } end
    t.unread = t.unread or 0
    return t
end

local function saveThread(t) return fsutil.writeTable(path(t.number), t) end

function M.contacts()
    return fsutil.readTable(DIR .. "contacts.lua") or {}
end

function M.setContact(number, name)
    local c = M.contacts()
    c[number] = { name = name }
    return fsutil.writeTable(DIR .. "contacts.lua", c)
end

function M.deleteContact(number)
    local c = M.contacts()
    c[number] = nil
    return fsutil.writeTable(DIR .. "contacts.lua", c)
end

function M.nameOf(number)
    local c = M.contacts()[number]
    if c and c.name and c.name ~= "" then return c.name end
    return number
end

function M.conversations()
    local out = {}
    if not fs.isDir(DIR) then return out end
    for _, f in ipairs(fs.list(DIR)) do
        local number = f:match("^(%d+%-%d+)%.lua$")
        if number then
            local t = M.thread(number)
            local last = t.msgs[#t.msgs]
            out[#out + 1] = { number = number, name = M.nameOf(number), last = last and last.body or "",
                ts = last and (last.sts or last.ts) or 0, unread = t.unread, dir = last and last.dir }
        end
    end
    table.sort(out, function(a, b) return a.ts > b.ts end)
    return out
end

function M.unreadTotal()
    local n = 0
    for _, c in ipairs(M.conversations()) do n = n + c.unread end
    return n
end

local function prune()
    local cap = settings.get("messages.maxBytes")
    if fsutil.size(DIR) <= cap then return false end
    local pruned = false
    local guard = 0
    while fsutil.size(DIR) > cap and guard < 200 do
        guard = guard + 1
        local biggest, bsize
        for _, f in ipairs(fs.list(DIR)) do
            local n = f:match("^(%d+%-%d+)%.lua$")
            if n then
                local s = fs.getSize(DIR .. f)
                if not bsize or s > bsize then biggest, bsize = n, s end
            end
        end
        if not biggest then break end
        local t = M.thread(biggest)
        if #t.msgs <= 1 then fs.delete(path(biggest)) else
            for _ = 1, math.max(1, math.floor(#t.msgs / 4)) do table.remove(t.msgs, 1) end
            saveThread(t)
        end
        pruned = true
    end
    return pruned
end

function M.outbox() return (fsutil.readTable(DIR .. "outbox.lua") or {}).items or {} end
local function saveOutbox(items) fsutil.writeTable(DIR .. "outbox.lua", { items = items }) end

function M.nextId(number)
    local meta = fsutil.readTable(DIR .. "meta.lua") or { counter = 0 }
    meta.counter = (meta.counter or 0) + 1
    fsutil.writeTable(DIR .. "meta.lua", meta)
    return number .. "-" .. meta.counter
end

function M.addOutgoing(myNumber, to, body)
    local id = M.nextId(myNumber)
    local ts = now()
    local t = M.thread(to)
    t.msgs[#t.msgs + 1] = { id = id, dir = "out", body = body, ts = ts, status = "sending" }
    local ok, err = saveThread(t)
    if not ok then return nil, err end
    local ob = M.outbox()
    ob[#ob + 1] = { to = to, id = id }
    saveOutbox(ob)
    prune()
    os.queueEvent("simplyos_msg")
    return id
end

function M.setStatus(id, status)
    local ob = M.outbox()
    local to
    for i, o in ipairs(ob) do
        if o.id == id then
            to = o.to
            if status == "delivered" or status == "failed" then table.remove(ob, i); saveOutbox(ob) end
            break
        end
    end
    if not to then
        -- already off the outbox (late delivered/expired): search threads
        for _, c in ipairs(M.conversations()) do
            local t = M.thread(c.number)
            for _, m in ipairs(t.msgs) do if m.id == id then to = c.number end end
        end
    end
    if not to then return end
    local t = M.thread(to)
    for _, m in ipairs(t.msgs) do
        if m.id == id then m.status = status end
    end
    saveThread(t)
    os.queueEvent("simplyos_msg")
end

-- returns "new", "dup" or nil (could not store)
function M.addIncoming(from, id, body, ts, sts)
    local t = M.thread(from)
    for _, m in ipairs(t.msgs) do
        if m.dir == "in" and m.id == id then return "dup" end
    end
    t.msgs[#t.msgs + 1] = { id = id, dir = "in", body = body, ts = ts or now(), sts = sts }
    table.sort(t.msgs, function(a, b)
        local ta, tb = a.sts or a.ts or 0, b.sts or b.ts or 0
        if ta ~= tb then return ta < tb end
        return tostring(a.id) < tostring(b.id)
    end)
    t.unread = (t.unread or 0) + 1
    local ok = saveThread(t)
    if ok then prune() end
    os.queueEvent("simplyos_msg")
    return ok and "new" or nil
end

function M.markRead(number)
    local t = M.thread(number)
    if t.unread ~= 0 then t.unread = 0; saveThread(t) end
end

function M.deleteThread(number)
    pcall(fs.delete, path(number))
    local ob = {}
    for _, o in ipairs(M.outbox()) do if o.to ~= number then ob[#ob + 1] = o end end
    saveOutbox(ob)
end

return M
