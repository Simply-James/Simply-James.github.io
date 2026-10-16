-- /os/lib/notify.lua
-- Notification records in /os/data/system/notifications.lua (newest first, 50 max, 30 days).
local fsutil = dofile("/os/lib/fsutil.lua")
local settings = dofile("/os/lib/settings.lua")
local M = {}
local FILE = "/os/data/system/notifications.lua"

local function load()
    local t = fsutil.readTable(FILE)
    return t and t.items or {}
end

local function save(items) fsutil.writeTable(FILE, { items = items }) end

function M.list() return load() end

function M.unread()
    local n = 0
    for _, r in ipairs(load()) do if not r.read then n = n + 1 end end
    return n
end

-- rec: {appId, appName, title, text}
function M.add(rec)
    if rec.appId and settings.get("notify.mute." .. rec.appId) then return nil end
    local items = load()
    local now = math.floor(os.epoch("utc") / 1000)
    rec.id = rec.id or (tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000, 9999)))
    rec.time = now
    rec.read = false
    table.insert(items, 1, rec)
    local keep = {}
    for _, r in ipairs(items) do
        if #keep < 50 and now - (r.time or now) < 30 * 86400 then keep[#keep + 1] = r end
    end
    save(keep)
    return rec
end

function M.remove(id)
    local out = {}
    for _, r in ipairs(load()) do if r.id ~= id then out[#out + 1] = r end end
    save(out)
end

function M.clear() save({}) end

function M.markAllRead()
    local items = load()
    for _, r in ipairs(items) do r.read = true end
    save(items)
end

return M
