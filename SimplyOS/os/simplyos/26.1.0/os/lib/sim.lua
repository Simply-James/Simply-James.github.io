-- /os/lib/sim.lua
-- Reads sim.lua from a floppy in a disk drive. Result cached for 3 s.
local M = {}
local cache, at = nil, -10

function M.read(force)
    if not force and os.clock() - at < 3 and cache then return cache[1], cache[2] end
    at = os.clock()
    local sim, why
    local ok, err = pcall(function()
        local drive = peripheral.find("drive")
        if not drive then why = "no drive" return end
        local name = peripheral.getName(drive)
        if not disk.isPresent(name) then why = "no disk" return end
        local path = disk.getMountPath(name)
        if not path or not fs.exists(path .. "/sim.lua") then why = "no sim.lua" return end
        local fn = loadfile(path .. "/sim.lua", "t", {})
        local t = fn and fn()
        if type(t) == "table" and type(t.number) == "string" and type(t.imsi) == "string" and type(t.key) == "string" then
            sim = t
        else
            why = "bad sim.lua"
        end
    end)
    if not ok then why = tostring(err) end
    cache = { sim, why }
    return sim, why
end

return M
