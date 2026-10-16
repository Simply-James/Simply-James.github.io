-- /server/store.lua
-- Safe persistent storage (one file). Write <file>.tmp, then replace the real file.
-- A missing or corrupt file returns the default and is logged, never a crash.
return function(S)
    local M = {}

    local function ensureDir(path)
        local dir = fs.getDir(path)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    end

    local function tryFile(p)
        if not fs.exists(p) or fs.isDir(p) then return nil end
        local f = fs.open(p, "r")
        if not f then return nil end
        local txt = f.readAll()
        f.close()
        if not txt then return nil end
        local ok, v = pcall(textutils.unserialize, txt)
        if ok and type(v) == "table" then return v end
        return nil
    end

    -- returns the stored table, or default
    function M.read(path, default)
        local v = tryFile(path)
        if v then return v end
        -- a world shutdown between delete and move leaves a complete .tmp
        v = tryFile(path .. ".tmp")
        if v then
            if S.log then
                S.log.warn("store", "recovered " .. path .. " from .tmp")
            end
            return v
        end
        if fs.exists(path) and S.log then
            S.log.warn("store", "corrupt file " .. path)
        end
        return default
    end

    -- force = true skips the free-space reserve (subscribers, secret)
    -- reserve overrides the default reserve (used for small storage disks)
    -- returns true, or false + reason ("full", "serialize", "io")
    function M.write(path, tbl, force, reserve)
        local ok, data = pcall(textutils.serialize, tbl)
        if not ok or type(data) ~= "string" then
            return false, "serialize"
        end

        ensureDir(path)
        if not force then
            reserve = reserve or (S.config and S.config.get("store.reserve")) or
                          0
            local dir = fs.getDir(path)
            if dir == "" then dir = "/" end
            -- the temp file exists next to the old file for a moment, so count the full size
            if fs.getFreeSpace(dir) - #data < reserve then
                return false, "full"
            end
        end

        local tmp = path .. ".tmp"
        local f = fs.open(tmp, "w")
        if not f then return false, "io" end
        f.write(data)
        f.close()
        if not fs.exists(tmp) or fs.getSize(tmp) ~= #data then
            pcall(fs.delete, tmp)
            return false, "io"
        end
        if fs.exists(path) then fs.delete(path) end
        fs.move(tmp, path)
        return true
    end

    -- raw (binary) files, same temp-then-replace rule
    function M.readRaw(path)
        if not fs.exists(path) or fs.isDir(path) then return nil end
        local f = fs.open(path, "rb")
        if not f then return nil end
        local data = f.readAll()
        f.close()
        return data
    end

    function M.writeRaw(path, data, reserve)
        ensureDir(path)
        local dir = fs.getDir(path)
        if dir == "" then dir = "/" end
        reserve = reserve or (S.config and S.config.get("store.reserve")) or 0
        if fs.getFreeSpace(dir) - #data < reserve then
            return false, "full"
        end
        local tmp = path .. ".tmp"
        local f = fs.open(tmp, "wb")
        if not f then return false, "io" end
        f.write(data)
        f.close()
        if not fs.exists(tmp) or fs.getSize(tmp) ~= #data then
            pcall(fs.delete, tmp)
            return false, "io"
        end
        if fs.exists(path) then fs.delete(path) end
        fs.move(tmp, path)
        return true
    end

    function M.exists(path)
        return fs.exists(path) or fs.exists(path .. ".tmp")
    end

    return M
end
