-- /os/lib/fsutil.lua
-- Safe file helpers: atomic-ish write, free space checks, sizes, rotating logs.
local M = {}

function M.ensureDir(path)
    if path ~= "" and not fs.exists(path) then fs.makeDir(path) end
end

function M.free()
    local f = fs.getFreeSpace("/")
    if type(f) ~= "number" then return math.huge end
    return f
end

function M.capacity()
    local ok, c = pcall(fs.getCapacity, "/")
    if ok and type(c) == "number" then return c end
    return nil
end

-- read a file, falls back to the .tmp copy if a write was interrupted
function M.read(path)
    local p = path
    if not fs.exists(p) and fs.exists(path .. ".tmp") then p = path .. ".tmp" end
    if not fs.exists(p) or fs.isDir(p) then return nil end
    local f = fs.open(p, "rb")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

function M.safeWrite(path, data)
    data = tostring(data)
    if M.free() < #data + 512 then return false, "no space" end
    M.ensureDir(fs.getDir(path))
    local tmp = path .. ".tmp"
    local f, err = fs.open(tmp, "wb")
    if not f then return false, err end
    local ok, werr = pcall(f.write, data)
    f.close()
    if not ok then pcall(fs.delete, tmp) return false, werr end
    if fs.getSize(tmp) ~= #data then pcall(fs.delete, tmp) return false, "short write" end
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

function M.readTable(path)
    local s = M.read(path)
    if not s then return nil end
    local ok, t = pcall(textutils.unserialize, s)
    if ok and type(t) == "table" then return t end
    return nil
end

function M.writeTable(path, t)
    return M.safeWrite(path, textutils.serialize(t))
end

function M.size(path)
    if not fs.exists(path) then return 0 end
    if not fs.isDir(path) then return fs.getSize(path) end
    local total = 0
    for _, name in ipairs(fs.list(path)) do total = total + M.size(fs.combine(path, name)) end
    return total
end

-- rotating log: /os/logs/<name>.txt, keeps 3 files of about 16 KB
function M.log(name, text)
    local p = "/os/logs/" .. name .. ".txt"
    if M.free() < 20000 then return false end
    M.ensureDir("/os/logs")
    if fs.exists(p) and fs.getSize(p) > 16000 then
        local p2 = "/os/logs/" .. name .. ".2.txt"
        local p1 = "/os/logs/" .. name .. ".1.txt"
        if fs.exists(p2) then fs.delete(p2) end
        if fs.exists(p1) then fs.move(p1, p2) end
        fs.move(p, p1)
    end
    local f = fs.open(p, "a")
    if not f then return false end
    f.write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(text) .. "\n")
    f.close()
    return true
end

return M
