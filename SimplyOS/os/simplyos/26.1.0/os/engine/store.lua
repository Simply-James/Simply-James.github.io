-- /os/engine/store.lua
-- Per-app save data in /os/data/<id>/save.lua, written on change (throttled).
local S = {}

function S.new(appId)
    local fsutil = dofile("/os/lib/fsutil.lua")
    local path = "/os/data/" .. appId .. "/save.lua"
    local data = fsutil.readTable(path) or {}
    local changed, last = false, 0
    local st = {}
    function st.get(key, default)
        local v = data[key]
        if v == nil then return default end
        return v
    end
    function st.set(key, value) data[key] = value; changed = true end
    function st.flush(force)
        if changed and (force or os.clock() - last > 2) then
            fsutil.writeTable(path, data)
            changed, last = false, os.clock()
        end
    end
    return st
end

return S
