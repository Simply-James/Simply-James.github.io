-- /os/lib/settings.lua
-- Settings storage. Flat dotted keys in /os/settings.lua. No caching: every call reads the file.
-- settings.get(key, fallback)  settings.set(key, value)  settings.getAll()
-- settings.reset(key)  settings.reset()  settings.defaults
local fsutil = dofile("/os/lib/fsutil.lua")

local M = {}
local FILE = "/os/settings.lua"

local D = {}
local function def(key, kind, default, extra)
    local d = extra or {}
    d.kind, d.default = kind, default
    D[key] = d
end

def("display.theme", "enum", "dark", { values = { "dark", "light" } })
def("display.accent", "enum", "jblue", { values = { "jblue", "jpink", "jpurple" } })
def("display.textLevel", "int", 1, { min = 1, max = 4 })
def("display.uiScale", "int", 100, { values = { 100, 125, 150 } })
def("home.columns", "int", 4, { min = 3, max = 6 })
def("display.autoRotate", "bool", true)
def("nav.order", "enum", "rhb", { values = { "rhb", "bhr" } })
def("clock.format", "enum", "24", { values = { "12", "24" } })
def("clock.source", "enum", "irl", { values = { "irl", "ingame" } })
def("phone.name", "text", "Phone", { max = 24 })
def("hardware.powerButtonSide", "enum", "none", { values = { "none", "bottom", "front", "back" } })
def("net.maxRange", "int", 0, { min = 0, max = 100000 })   -- 0 = not calibrated yet
def("messages.maxBytes", "int", 100000, { min = 10000, max = 10000000 })
def("notify.server", "bool", true)
def("dev.enabled", "bool", false)
def("dev.fpsOverlay", "bool", false)
def("dev.logging", "bool", false)
def("dev.watchdog", "bool", false)  -- off by default: timeout units unknown, timeout 0 trips instantly

M.defaults = {}
for k, d in pairs(D) do M.defaults[k] = d.default end

local function defOf(key)
    if D[key] then return D[key] end
    if key:sub(1, 12) == "notify.mute." then return { kind = "bool", default = false } end
    return nil
end

local function coerce(d, v)
    if v == nil then return nil end
    if d.kind == "bool" then
        if type(v) == "boolean" then return v end
        return nil
    elseif d.kind == "int" then
        if type(v) ~= "number" then return nil end
        v = math.floor(v)
        if d.values then
            for _, a in ipairs(d.values) do if a == v then return v end end
            return nil
        end
        if d.min and v < d.min then return nil end
        if d.max and v > d.max then return nil end
        return v
    elseif d.kind == "enum" then
        v = tostring(v)
        for _, a in ipairs(d.values) do if a == v then return v end end
        return nil
    elseif d.kind == "text" then
        if type(v) ~= "string" then return nil end
        if d.max and #v > d.max then v = v:sub(1, d.max) end
        return v
    end
    return nil
end

local function load()
    return fsutil.readTable(FILE) or {}
end

function M.get(key, fallback)
    local stored = load()[key]
    local d = defOf(key)
    if d then
        local v = coerce(d, stored)
        if v ~= nil then return v end
        return d.default
    end
    if stored ~= nil then return stored end
    return fallback
end

function M.set(key, value)
    local d = defOf(key)
    if d then
        value = coerce(d, value)
        if value == nil then return false, "invalid value" end
    end
    local t = load()
    t[key] = value
    return fsutil.writeTable(FILE, t)
end

function M.getAll()
    local out = {}
    for k, v in pairs(M.defaults) do out[k] = v end
    for k, v in pairs(load()) do
        local d = defOf(k)
        if d then
            local c = coerce(d, v)
            if c ~= nil then out[k] = c end
        else
            out[k] = v
        end
    end
    return out
end

function M.reset(key)
    if key == nil then return fsutil.writeTable(FILE, {}) end
    local t = load()
    t[key] = nil
    return fsutil.writeTable(FILE, t)
end

return M
