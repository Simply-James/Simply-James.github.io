-- /server/storage.lua
-- Mass storage over any number of disk drives. A disk labeled "Storage_<anything>" is a storage
-- volume. Any other disk in a drive is a possible SIM disk. Nothing here assumes a drive count.
-- Data files live at <mount>/simplyos/<rel>. The main disk (/server/data/<rel>) is always the
-- last volume: it is read and listed like the others, and written to only when no Storage_ disk
-- has room (config storage.fallback).
-- Critical state (config, subscribers, secret) stays on the main disk and does not use this module.
return function(S)
    local M = {sims = {}}
    local PREFIX = "Storage_"
    local vols = {}
    local MAIN = {
        label = "main",
        drive = "-",
        mount = "/",
        base = "/server/data",
        main = true
    }

    local function isStorageLabel(l)
        return type(l) == "string" and #l > #PREFIX and l:sub(1, #PREFIX) ==
                   PREFIX
    end

    local function natural(label)
        return (label:gsub("%d+", function(n)
            return string.format("%08d", tonumber(n))
        end))
    end

    local function log(level, text)
        if S.log then S.log[level]("storage", text) end
    end

    function M.scan()
        local newVols, newSims, seen = {}, {}, {}
        for _, name in ipairs(peripheral.getNames()) do
            pcall(function()
                if not peripheral.hasType(name, "drive") then
                    return
                end
                if not disk.isPresent(name) then return end
                local label = disk.getLabel(name)
                local mount = disk.getMountPath(name)
                if isStorageLabel(label) then
                    if not mount then return end
                    if seen[label] then
                        log("warn", "duplicate label " .. label .. " on " ..
                                name .. ", ignored")
                        return
                    end
                    seen[label] = true
                    newVols[#newVols + 1] = {
                        label = label,
                        drive = name,
                        mount = mount,
                        base = mount .. "/simplyos"
                    }
                else
                    newSims[#newSims + 1] = {
                        drive = name,
                        label = label,
                        mount = mount
                    }
                end
            end)
        end
        table.sort(newVols, function(a, b)
            return natural(a.label) < natural(b.label)
        end)
        table.sort(newSims, function(a, b) return a.drive < b.drive end)

        local old = {}
        for _, v in ipairs(vols) do old[v.label] = true end
        local new = {}
        for _, v in ipairs(newVols) do
            new[v.label] = true
            if not old[v.label] then
                log("info",
                    "volume " .. v.label .. " online (" .. v.drive .. ")")
            end
        end
        for l in pairs(old) do
            if not new[l] then
                log("warn", "volume " .. l .. " went offline")
            end
        end
        vols, M.sims = newVols, newSims
        return vols
    end

    local function info(v)
        local ok1, cap = pcall(fs.getCapacity, v.mount)
        local ok2, free = pcall(fs.getFreeSpace, v.mount)
        v.cap = ok1 and cap or 0
        v.free = ok2 and free or 0
        return v
    end

    -- storage volumes only, with fresh capacity numbers
    function M.volumes()
        for _, v in ipairs(vols) do info(v) end
        return vols
    end

    -- storage volumes followed by the main disk
    local function all()
        local list = {}
        for _, v in ipairs(vols) do list[#list + 1] = v end
        list[#list + 1] = MAIN
        return list
    end

    local function path(v, rel) return v.base .. "/" .. rel end

    -- first volume that holds rel (also accepts a leftover .tmp)
    function M.find(rel)
        for _, v in ipairs(all()) do
            local p = path(v, rel)
            if fs.exists(p) or fs.exists(p .. ".tmp") then
                return v, p
            end
        end
    end

    function M.read(rel, default)
        local _, p = M.find(rel)
        if not p then return default end
        return S.store.read(p, default)
    end

    -- every copy (a disk that was offline can leave a second copy behind)
    function M.readAll(rel)
        local out = {}
        for _, v in ipairs(all()) do
            local p = path(v, rel)
            if fs.exists(p) or fs.exists(p .. ".tmp") then
                local t = S.store.read(p, nil)
                if t then out[#out + 1] = t end
            end
        end
        return out
    end

    local function deleteOn(v, rel)
        local p = path(v, rel)
        pcall(function()
            if fs.exists(p) then fs.delete(p) end
            if fs.exists(p .. ".tmp") then fs.delete(p .. ".tmp") end
        end)
    end

    function M.delete(rel) for _, v in ipairs(all()) do deleteOn(v, rel) end end

    -- Writes where the file already lives; if that volume is full or gone, on the volume with the
    -- most free space. Removes other copies after a successful write.
    -- returns true, volumeLabel   or   false, reason
    function M.write(rel, tbl)
        local reserve = S.config.get("storage.reserve")
        local existing = M.find(rel)
        local order = {}
        if existing and not existing.main then
            order[#order + 1] = existing
        end
        local others = {}
        for _, v in ipairs(M.volumes()) do
            if v ~= existing then others[#others + 1] = v end
        end
        table.sort(others, function(a, b) return a.free > b.free end)
        for _, v in ipairs(others) do order[#order + 1] = v end
        if S.config.get("storage.fallback") or #vols == 0 then
            order[#order + 1] = MAIN
        end

        local lastWhy = "full"
        for _, v in ipairs(order) do
            local ok, done, why = pcall(S.store.write, path(v, rel), tbl, false,
                                        (not v.main) and reserve or nil)
            if ok and done then
                for _, o in ipairs(all()) do
                    if o ~= v then deleteOn(o, rel) end
                end
                return true, v.label
            end
            if ok and why and why ~= "full" then lastWhy = why end
        end
        return false, lastWhy
    end

    -- names (not paths) of files in a directory across all volumes, sorted
    function M.list(dir)
        local seen, out = {}, {}
        for _, v in ipairs(all()) do
            local p = path(v, dir)
            local ok, names = pcall(function()
                if fs.exists(p) and fs.isDir(p) then
                    return fs.list(p)
                end
                return {}
            end)
            if ok then
                for _, n in ipairs(names) do
                    n = n:gsub("%.tmp$", "")
                    if not seen[n] then
                        seen[n] = true;
                        out[#out + 1] = n
                    end
                end
            end
        end
        table.sort(out)
        return out
    end

    -- raw files (app and update files) ---------------------------------------
    -- writes on the volume with the most free space; the main disk only if storage.fallback
    function M.writeRaw(rel, data)
        local reserve = S.config.get("storage.reserve")
        local existing = M.find(rel)
        local order, others = {}, {}
        for _, v in ipairs(M.volumes()) do others[#others + 1] = v end
        table.sort(others, function(a, b)
            if a == existing then return true end
            if b == existing then return false end
            return a.free > b.free
        end)
        for _, v in ipairs(others) do order[#order + 1] = v end
        if S.config.get("storage.fallback") or #vols == 0 then
            order[#order + 1] = MAIN
        end
        local lastWhy = "full"
        for _, v in ipairs(order) do
            local ok, done, why = pcall(S.store.writeRaw, path(v, rel), data,
                                        (not v.main) and reserve or nil)
            if ok and done then
                for _, o in ipairs(all()) do
                    if o ~= v then deleteOn(o, rel) end
                end
                return true, v.label
            end
            if ok and why and why ~= "full" then lastWhy = why end
        end
        return false, lastWhy
    end

    function M.readRaw(rel)
        local _, p = M.find(rel)
        return p and S.store.readRaw(p) or nil
    end

    -- a full path usable with other programs (the editor): existing file, or a new one on the roomiest volume
    function M.pathFor(rel)
        local _, p = M.find(rel)
        if p then return p end
        local best
        for _, v in ipairs(M.volumes()) do
            if not best or v.free > best.free then best = v end
        end
        return path(best or MAIN, rel)
    end

    -- every file under dir (relative paths), across volumes, sorted
    function M.walk(dir)
        local seen, out = {}, {}
        local function rec(base, rel)
            local p = base .. "/" .. rel
            if not fs.exists(p) or not fs.isDir(p) then return end
            for _, n in ipairs(fs.list(p)) do
                local sub = rel .. "/" .. n
                if fs.isDir(base .. "/" .. sub) then
                    rec(base, sub)
                elseif not n:match("%.tmp$") and not seen[sub] then
                    seen[sub] = true
                    out[#out + 1] = sub:sub(#dir + 2)
                end
            end
        end
        for _, v in ipairs(all()) do pcall(rec, v.base, dir) end
        table.sort(out)
        return out
    end

    function M.deleteTree(dir)
        for _, v in ipairs(all()) do
            local p = path(v, dir)
            pcall(function() if fs.exists(p) then fs.delete(p) end end)
        end
    end

    function M.totals()
        local cap, free = 0, 0
        for _, v in ipairs(M.volumes()) do
            cap = cap + v.cap;
            free = free + v.free
        end
        return {count = #vols, cap = cap, free = free}
    end

    -- task: rescan on disk events and on a timer
    function M.run()
        M.scan()
        local timer = os.startTimer(S.config.get("storage.scanSeconds"))
        while true do
            local ev, a = os.pullEvent()
            if ev == "timer" and a == timer then
                M.scan()
                timer = os.startTimer(S.config.get("storage.scanSeconds"))
            elseif ev == "disk" or ev == "disk_eject" or ev == "peripheral" or
                ev == "peripheral_detach" then
                M.scan()
            end
        end
    end

    return M
end
