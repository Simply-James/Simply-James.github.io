-- /server/repo.lua
-- App manager and package host. Packages (kind os | engine | app) are mirrored from the remote
-- repo (source.lua) onto the storage disks, can be edited by an admin, and are served to phones only
-- when enabled. One active version per package.
-- Files:   repo/<kind>/<id>/<version>/manifest.lua and repo/<kind>/<id>/<version>/files/<path>
-- State:   /server/data/repo/state.lua (main disk, included in backups)
-- Phone packets (session): repo.list, repo.manifest, repo.file, repo.info, update.check
return function(S)
    local M = {}
    local STATE = "/server/data/repo/state.lua"
    local CHUNK = 8000
    local st = {packages = {}}

    local function key(kind, id) return kind .. ":" .. id end
    local function rel(kind, id, ver)
        return "repo/" .. kind .. "/" .. id .. "/" .. ver
    end

    function M.load()
        st = S.store.read(STATE, {packages = {}})
        st.packages = st.packages or {}
    end

    local function save()
        local ok = S.store.write(STATE, st, true)
        if S.backup then S.backup.touch() end
        return ok
    end

    function M.exportState() return st end
    function M.importState(t)
        st = type(t) == "table" and t or {packages = {}}
        st.packages = st.packages or {}
        save()
    end

    local function pkg(kind, id, create)
        local p = st.packages[key(kind, id)]
        if not p and create then
            p = {
                kind = kind,
                id = id,
                name = id,
                enabled = false,
                versions = {}
            }
            st.packages[key(kind, id)] = p
        end
        return p
    end

    local function readManifest(kind, id, ver)
        return S.storage.read(rel(kind, id, ver) .. "/manifest.lua", nil)
    end

    -- remote catalogue --------------------------------------------------------
    local remote
    function M.refreshRemote()
        local r, err = S.source.index()
        if not r then return false, err end
        remote = r
        return true
    end
    function M.remote() return remote end

    -- mirroring ---------------------------------------------------------------
    -- downloads and verifies every file of a remote version onto the storage disks.
    -- say(text) is called with progress lines. returns true, or false + reason
    function M.mirror(kind, id, ver, say)
        say = say or function() end
        if not S.source.kinds[kind] or not S.source.validId(id) or
            not S.source.validVersion(ver) then
            return false, "bad package name"
        end
        say("manifest...")
        local m, err = S.source.manifest(kind, id, ver)
        if not m then return false, "manifest: " .. tostring(err) end

        local total = 0
        for _, f in ipairs(m.files) do total = total + f.size end
        local free = S.storage.totals().free
        if S.config.get("storage.fallback") then
            free = free +
                       math.max(0, fs.getFreeSpace("/") -
                                    S.config.get("store.reserve"))
        end
        if total + #m.files * 200 > free then
            return false,
                   "not enough storage: need " .. S.util.bytes(total) ..
                       ", free " .. S.util.bytes(free)
        end

        S.storage.deleteTree(rel(kind, id, ver))
        local function fail(text)
            S.storage.deleteTree(rel(kind, id, ver))
            return false, text
        end
        for i, f in ipairs(m.files) do
            say(i .. "/" .. #m.files .. " " .. f.path .. " (" ..
                    S.util.bytes(f.size) .. ")")
            local blob, e = S.source.file(kind, id, ver, f.path)
            if not blob then
                return fail(f.path .. ": " .. tostring(e))
            end
            if #blob ~= f.size then
                return fail(f.path .. ": wrong size")
            end
            if S.crypto.sha256(blob) ~= f.sha256 then
                return fail(f.path .. ": sha256 mismatch")
            end
            local ok, why = S.storage.writeRaw(
                                rel(kind, id, ver) .. "/files/" .. f.path, blob)
            if not ok then
                return
                    fail(f.path .. ": cannot store (" .. tostring(why) .. ")")
            end
        end
        m.modified = false
        local ok = S.storage.write(rel(kind, id, ver) .. "/manifest.lua", m)
        if not ok then return fail("cannot store manifest") end

        local p = pkg(kind, id, true)
        p.name = tostring(m.name or id)
        local old = p.versions[ver]
        p.versions[ver] = {
            mirrored = true,
            modified = false,
            files = #m.files,
            size = total,
            at = S.util.now(),
            approved = old and old.approved or false
        }
        save()
        S.log.info("repo", "mirrored " .. key(kind, id) .. " " .. ver)
        return true
    end

    -- recompute sizes and sha256 for every file on disk (after an admin edit)
    function M.rehash(kind, id, ver)
        local m = readManifest(kind, id, ver)
        if not m then return false, "version is not mirrored" end
        local base = rel(kind, id, ver) .. "/files"
        local files, total = {}, 0
        for _, path in ipairs(S.storage.walk(base)) do
            local data = S.storage.readRaw(base .. "/" .. path)
            if data then
                files[#files + 1] = {
                    path = path,
                    size = #data,
                    sha256 = S.crypto.sha256(data)
                }
                total = total + #data
            end
        end
        m.files = files
        m.modified = true
        local has = {}
        for _, f in ipairs(files) do has[f.path] = true end
        if m.uninstall and not has[m.uninstall] then m.uninstall = nil end
        S.storage.write(rel(kind, id, ver) .. "/manifest.lua", m)
        local v = pkg(kind, id, true).versions[ver] or {}
        v.mirrored, v.modified, v.files, v.size = true, true, #files, total
        pkg(kind, id, true).versions[ver] = v
        save()
        S.log.info("repo", "rehashed " .. key(kind, id) .. " " .. ver .. " (" ..
                       #files .. " files)")
        return true
    end

    function M.filePath(kind, id, ver, path)
        return rel(kind, id, ver) .. "/files/" .. path
    end

    function M.files(kind, id, ver)
        return S.storage.walk(rel(kind, id, ver) .. "/files")
    end

    function M.deleteVersion(kind, id, ver)
        local p = pkg(kind, id)
        if not p then return false end
        S.storage.deleteTree(rel(kind, id, ver))
        p.versions[ver] = nil
        if p.active == ver then p.active, p.enabled = nil, false end
        if next(p.versions) == nil then st.packages[key(kind, id)] = nil end
        save()
        S.log.info("repo", "deleted " .. key(kind, id) .. " " .. ver)
        return true
    end

    -- serving control ---------------------------------------------------------
    function M.setActive(kind, id, ver)
        local p = pkg(kind, id)
        if not p or not p.versions[ver] or not p.versions[ver].mirrored then
            return false, "not mirrored"
        end
        p.active, p.enabled = ver, true
        local announce = p.announced ~= ver
        p.announced = ver
        save()
        S.log.info("repo", "serving " .. key(kind, id) .. " " .. ver)
        if announce and S.config.get("push.autoUpdates") and S.push then
            S.push.broadcast({
                title = "Update available",
                text = p.name .. " " .. ver,
                kind = kind,
                appId = id
            })
        end
        return true
    end

    function M.disable(kind, id)
        local p = pkg(kind, id)
        if not p then return false end
        p.enabled = false
        save()
        S.log.info("repo", "stopped serving " .. key(kind, id))
        return true
    end

    function M.setApproved(kind, id, ver, value)
        local p = pkg(kind, id)
        if not p or not p.versions[ver] then return false end
        p.versions[ver].approved = value and true or false
        save()
        return true
    end

    -- hosted packages for the admin screens: { {kind,id,name,active,enabled,versions={ver=info}} }
    function M.list()
        local out = {}
        for _, p in pairs(st.packages) do out[#out + 1] = p end
        table.sort(out, function(a, b)
            if a.kind ~= b.kind then return a.kind < b.kind end
            return a.id < b.id
        end)
        return out
    end

    function M.get(kind, id) return pkg(kind, id) end

    function M.sortedVersions(p)
        local list = {}
        for v in pairs(p.versions) do list[#list + 1] = v end
        table.sort(list, function(a, b) return S.source.newer(a, b) end)
        return list
    end

    -- drop state for versions whose files are gone (a lost disk, a restore on a new machine)
    function M.check()
        local changed = false
        for _, p in pairs(st.packages) do
            for ver, v in pairs(p.versions) do
                if v.mirrored and not readManifest(p.kind, p.id, ver) then
                    v.mirrored = false
                    changed = true
                    S.log.warn("repo",
                               "files missing for " .. key(p.kind, p.id) .. " " ..
                                   ver)
                    if p.active == ver then p.enabled = false end
                end
            end
        end
        if changed then save() end
    end

    -- serving to phones -------------------------------------------------------
    local function served(kind, id)
        local p = pkg(kind, id)
        if not p or not p.enabled or not p.active then return nil end
        local m = readManifest(kind, id, p.active)
        if not m then return nil end
        m.approved = p.versions[p.active].approved or false
        return m, p
    end

    S.net.on("repo.info", function(id, msg, d, s)
        S.net.send(id, "repo.info", msg.rid, {
            baseUrl = S.config.get("repo.baseUrl"),
            admin = S.subscribers.isAdmin(s.number)
        })
    end, {session = true})

    S.net.on("repo.list", function(id, msg, d)
        local items = {}
        for _, p in ipairs(M.list()) do
            if p.enabled and p.active and (d.kind == nil or d.kind == p.kind) then
                local v = p.versions[p.active]
                items[#items + 1] = {
                    kind = p.kind,
                    id = p.id,
                    name = p.name,
                    version = p.active,
                    size = v.size,
                    approved = v.approved or false,
                    modified = v.modified or false
                }
            end
        end
        local per = 20
        local pages = math.max(1, math.ceil(#items / per))
        local page = math.min(math.max(1, tonumber(d.page) or 1), pages)
        local out = {}
        for i = (page - 1) * per + 1, math.min(#items, page * per) do
            out[#out + 1] = items[i]
        end
        S.net.send(id, "repo.list.reply", msg.rid,
                   {items = out, page = page, pages = pages})
    end, {session = true})

    S.net.on("repo.manifest", function(id, msg, d)
        if not S.source.kinds[d.kind] or not S.source.validId(d.id) then
            S.net.err(id, msg, "notfound", "no such package")
            return
        end
        local m = served(d.kind, d.id)
        if not m then
            S.net.err(id, msg, "notfound", "not available")
            return
        end
        S.net.send(id, "repo.manifest.reply", msg.rid, m)
    end, {session = true})

    -- repo.file {kind,id,version,path,part}: part starts at 1; reply repo.chunk {..., n, total, data, sha256 on the last}
    S.net.on("repo.file", function(id, msg, d)
        if not S.source.kinds[d.kind] or not S.source.validId(d.id) or
            not S.source.validPath(d.path) then
            S.net.err(id, msg, "notfound", "bad request")
            return
        end
        local m, p = served(d.kind, d.id)
        if not m or d.version ~= p.active then
            S.net.err(id, msg, "notfound", "not available")
            return
        end
        local entry
        for _, f in ipairs(m.files) do
            if f.path == d.path then
                entry = f
                break
            end
        end
        if not entry then
            S.net.err(id, msg, "notfound", "no such file")
            return
        end
        local data = S.storage.readRaw(
                         rel(d.kind, d.id, p.active) .. "/files/" .. d.path)
        if not data then
            S.net.err(id, msg, "notfound", "file unavailable")
            return
        end
        local total = math.max(1, math.ceil(#data / CHUNK))
        local n = math.floor(tonumber(d.part) or 1)
        if n < 1 or n > total then
            S.net.err(id, msg, "notfound", "no such part")
            return
        end
        S.net.send(id, "repo.chunk", msg.rid, {
            kind = d.kind,
            id = d.id,
            version = p.active,
            path = d.path,
            n = n,
            total = total,
            data = data:sub((n - 1) * CHUNK + 1, n * CHUNK),
            sha256 = n == total and entry.sha256 or nil
        })
    end, {session = true})

    -- update.check {os, ge, apps={id=version}} -> update.list {items}
    S.net.on("update.check", function(id, msg, d)
        local items = {}
        local function consider(kind, pid, have)
            local m, p = served(kind, pid)
            if m and S.source.newer(p.active, have or "0.0.0") then
                items[#items + 1] = {
                    kind = kind,
                    id = pid,
                    name = p.name,
                    version = p.active,
                    size = p.versions[p.active].size,
                    notes = m.note or "",
                    modified = p.versions[p.active].modified or false
                }
            end
        end
        consider("os", "simplyos", tostring(d.os or "0.0.0"))
        consider("engine", "ge", tostring(d.ge or "0.0.0"))
        if type(d.apps) == "table" then
            for aid, ver in pairs(d.apps) do
                if S.source.validId(aid) then
                    consider("app", aid, tostring(ver))
                end
            end
        end
        S.net.send(id, "update.list", msg.rid, {items = items})
    end, {session = true})

    return M
end
