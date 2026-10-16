-- /server/backup.lua
-- Backup of everything that cannot be rebuilt: master secret (all SIM keys), subscribers, config
-- overrides and the app manager state. Mirrored app files are NOT in it (they live on the storage
-- disks; they can also be mirrored again from the remote repo).
--   floppy export  admin menu -> Backup. Optional passphrase (AES). Keep the floppy off the server.
--   local copy     backup/latest.lua (+ previous.lua) on the storage disks, written automatically when
--                  something changed. Plain, no passphrase: it is for "main disk died", not for theft.
-- Restore from either one: admin menu -> Backup -> Restore.
return function(S)
    local M = {}
    local META = "/server/data/backup.lua"
    local LATEST, PREVIOUS = "backup/latest.lua", "backup/previous.lua"
    local meta = {}
    local dirty, lastWrite = true, 0

    function M.load() meta = S.store.read(META, {}) end
    function M.touch() dirty = true end
    function M.info()
        return {
            lastLocal = meta.lastLocal,
            lastExport = meta.lastExport,
            hasLocal = S.storage.find(LATEST) ~= nil
        }
    end

    local function saveMeta() S.store.write(META, meta, true) end

    local function snapshot()
        local sub = S.subscribers.exportAll()
        return {
            format = 1,
            version = S.version,
            created = S.util.now(),
            secret = sub.master,
            subscribers = sub.subs,
            config = S.config.exportOverrides(),
            repo = S.repo.exportState()
        }
    end

    local function derive(pass, salt)
        local h = S.crypto.sha256(pass .. salt)
        for _ = 2, 1000 do h = S.crypto.sha256(h .. pass) end
        return h
    end

    -- the file table that gets written to a disk
    local function pack(pass)
        if not S.subscribers.exportAll().master then
            return nil, "no master secret in memory"
        end
        local payload = textutils.serialize(snapshot())
        if pass and pass ~= "" then
            local salt = S.crypto.random(16)
            return {
                format = 1,
                enc = true,
                salt = salt,
                created = S.util.now(),
                data = S.cipher.seal(derive(pass, salt), payload)
            }
        end
        return {format = 1, enc = false, created = S.util.now(), data = payload}
    end

    -- file table -> snapshot table, or nil + reason
    local function unpack(file, pass)
        if type(file) ~= "table" or file.format ~= 1 or type(file.data) ~=
            "string" then return nil, "not a backup file" end
        local payload = file.data
        if file.enc then
            if not pass or pass == "" then
                return nil, "passphrase needed"
            end
            payload = S.cipher.open(derive(pass, file.salt or ""), file.data)
            if not payload then
                return nil, "wrong passphrase or damaged file"
            end
        end
        local ok, snap = pcall(textutils.unserialize, payload)
        if not ok or type(snap) ~= "table" or type(snap.secret) ~= "string" or
            #snap.secret ~= 64 or type(snap.subscribers) ~= "table" then
            return nil, "backup content is invalid"
        end
        return snap
    end
    M.isEncrypted = function(file)
        return type(file) == "table" and file.enc == true
    end

    -- local copy ---------------------------------------------------------------
    function M.writeLocal()
        local file, why = pack(nil)
        if not file then return false, why end
        local old = S.storage.read(LATEST, nil)
        if old then S.storage.write(PREVIOUS, old) end
        local ok, w = S.storage.write(LATEST, file)
        if not ok then
            S.log.warn("backup", "local copy failed: " .. tostring(w))
            return false, w
        end
        meta.lastLocal = S.util.now()
        saveMeta()
        dirty, lastWrite = false, S.util.now()
        S.log.info("backup", "local copy written")
        return true
    end

    -- housekeeping: write the local copy when something changed
    function M.tick()
        if dirty and S.util.now() - lastWrite >=
            S.config.get("backup.localMinutes") * 60 then M.writeLocal() end
    end

    function M.readLocal() return S.storage.read(LATEST, nil) end

    -- floppy ---------------------------------------------------------------------
    -- disk = a SIM-style drive entry {drive, mount}. returns true or false + reason
    function M.exportToDisk(disk_, pass)
        local file, why = pack(pass)
        if not file then return false, why end
        local text = textutils.serialize(file)
        local mount = disk_.mount
        if fs.exists(fs.combine(mount, "sim.lua")) then
            return false, "that disk is a SIM"
        end
        if fs.getFreeSpace(mount) < #text + 500 then
            return false,
                   "disk too small (" .. S.util.bytes(#text) .. " needed)"
        end
        local f = fs.open(fs.combine(mount, "backup.lua"), "w")
        if not f then return false, "cannot write to the disk" end
        f.write(text)
        f.close()
        pcall(disk.setLabel, disk_.drive, "Backup " .. os.date("!%Y-%m-%d"))
        local back = M.readDisk(mount)
        if not back or back.data ~= file.data then
            pcall(fs.delete, fs.combine(mount, "backup.lua"))
            return false, "read back did not match"
        end
        meta.lastExport = S.util.now()
        saveMeta()
        S.log.info("backup", "exported to floppy" ..
                       ((pass and pass ~= "") and " (passphrase)" or ""))
        return true
    end

    function M.readDisk(mount)
        local p = fs.combine(mount, "backup.lua")
        if not fs.exists(p) then return nil end
        local f = fs.open(p, "r")
        if not f then return nil end
        local text = f.readAll()
        f.close()
        local ok, t = pcall(textutils.unserialize, text)
        return ok and type(t) == "table" and t or nil
    end

    -- restore ----------------------------------------------------------------------
    -- replaces secret, subscribers, config overrides and app manager state. returns true or false + reason
    function M.restore(file, pass)
        local snap, why = unpack(file, pass)
        if not snap then return false, why end
        S.subscribers.importAll(snap.secret, snap.subscribers)
        S.config.importOverrides(snap.config or {})
        S.repo.importState(snap.repo or {packages = {}})
        S.repo.check()
        S.log.info("backup", "restored backup made " ..
                       S.util.stamp(snap.created or 0) .. " UTC")
        return true, snap
    end

    return M
end
