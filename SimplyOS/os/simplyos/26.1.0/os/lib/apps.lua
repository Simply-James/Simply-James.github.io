-- /os/lib/apps.lua
-- Lists installed apps from /os/apps/<id>/metadata.lua (Lua table, or old key=value file).
local fsutil = dofile("/os/lib/fsutil.lua")
local M = {}

local function readMeta(dir)
    local p = dir .. "/metadata.lua"
    if not fs.exists(p) then return nil end
    local meta
    pcall(function()
        local fn = loadfile(p, "t", {})
        if fn then
            local m = fn()
            if type(m) == "table" then meta = m end
        end
    end)
    if meta then return meta end
    local s = fsutil.read(p)
    if not s then return nil end
    meta = {}
    for line in s:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*[=:]%s*(.-)%s*$")
        if k then
            if v == "true" then v = true elseif v == "false" then v = false end
            meta[k] = v
        end
    end
    return meta
end

function M.meta(id) return readMeta("/os/apps/" .. id) end

function M.list()
    local out = {}
    if not fs.isDir("/os/apps") then return out end
    for _, id in ipairs(fs.list("/os/apps")) do
        local dir = "/os/apps/" .. id
        if fs.isDir(dir) then
            local m = readMeta(dir) or {}
            local icon = dir .. "/AppIcon.png"
            out[#out + 1] = {
                id = id, dir = dir, meta = m,
                name = tostring(m.name or id),
                version = tostring(m.version or "?"),
                system = m.system == true, dev = m.dev == true,
                fullscreen = m.fullscreen == true,
                icon = fs.exists(icon) and icon or nil,
                start = m.start or "main.lua",
            }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function M.find(id)
    for _, a in ipairs(M.list()) do if a.id == id then return a end end
end

return M
