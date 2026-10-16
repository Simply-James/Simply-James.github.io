-- /os/lib/repo.lua
-- Package client for the root server (ROOT_SERVER_DEVDOC_ADDENDUM section 4) and developer direct download.
local fsutil = dofile("/os/lib/fsutil.lua")
local crypto = dofile("/os/lib/crypto.lua")
local appslib = dofile("/os/lib/apps.lua")
local R = {}

local function net() return _G.SimplyOS and _G.SimplyOS.net end

local function errText(r)
    if type(r.d) == "table" then return tostring(r.d.text or r.d.code or r.t) end
    return tostring(r.t)
end

local function call(t, d, timeout)
    local N = net()
    if not N then return nil, "no network service" end
    local r, err = N.request(t, d, timeout or 10)
    if not r then return nil, err end
    if r.t == "err" then return nil, errText(r) end
    return r.d or {}
end

function R.info() return call("repo.info", {}) end

function R.list(kind, page)
    return call("repo.list", { kind = kind, page = page or 1 })
end

function R.localVersions()
    local v = { os = "?", ge = "?", apps = {} }
    pcall(function()
        local ver = dofile("/os/version.lua")
        v.os, v.ge = ver.os, ver.ge
    end)
    for _, a in ipairs(appslib.list()) do v.apps[a.id] = a.version end
    return v
end

function R.updates()
    local v = R.localVersions()
    local d, err = call("update.check", { os = v.os, ge = v.ge, apps = v.apps }, 12)
    if not d then return nil, err end
    return d.items or {}
end

local function safePath(p)
    if type(p) ~= "string" or p == "" or p:sub(1, 1) == "/" or p:find("..", 1, true) then return false end
    return true
end

-- writes verified files to tmp, then moves them into place
local function commit(kind, id, m, tmp)
    if kind == "app" then
        local root = m.root
        if type(root) ~= "string" or root:sub(1, 9) ~= "/os/apps/" or root:find("..", 1, true) then
            return false, "bad install root"
        end
        pcall(fs.delete, root)
        for _, f in ipairs(m.files) do
            local dest = fs.combine(root, f.path)
            fsutil.ensureDir(fs.getDir(dest))
            fs.move(tmp .. "/" .. f.path, dest)
        end
    else
        for _, f in ipairs(m.files) do
            local dest = "/" .. f.path
            if not (dest == "/startup.lua" or dest:sub(1, 4) == "/os/") then return false, "bad path " .. f.path end
            fsutil.ensureDir(fs.getDir(dest))
            if fs.exists(dest) then fs.delete(dest) end
            fs.move(tmp .. "/" .. f.path, dest)
        end
    end
    pcall(fs.delete, tmp)
    return true
end

local function checkManifest(m, kind, id)
    if type(m) ~= "table" or type(m.files) ~= "table" or #m.files == 0 then return false, "bad manifest" end
    if m.id ~= id or m.kind ~= kind then return false, "manifest does not match" end
    for _, f in ipairs(m.files) do
        if not safePath(f.path) or type(f.size) ~= "number" or type(f.sha256) ~= "string" then
            return false, "bad file entry"
        end
    end
    return true
end

local function verifyAndStore(f, data, tmp)
    if #data ~= f.size then return false, "size mismatch: " .. f.path end
    if crypto.sha256(data) ~= f.sha256:lower() then return false, "checksum mismatch: " .. f.path end
    local ok, err = fsutil.safeWrite(tmp .. "/" .. f.path, data)
    if not ok then return false, "write failed: " .. tostring(err) end
    return true
end

-- fetch: function(f, m) -> data or nil, err
local function installFrom(kind, id, m, fetch, progress)
    local ok, why = checkManifest(m, kind, id)
    if not ok then return false, why end
    local total = 0
    for _, f in ipairs(m.files) do total = total + f.size end
    if fsutil.free() < total * 2 + 60000 then return false, "not enough space" end
    local tmp = "/os/tmp/" .. kind .. "-" .. id
    pcall(fs.delete, tmp)
    local done = 0
    for _, f in ipairs(m.files) do
        progress(f.path, total > 0 and done / total or 0)
        local data, err = fetch(f, m)
        if not data then pcall(fs.delete, tmp) return false, err end
        local ok2, err2 = verifyAndStore(f, data, tmp)
        if not ok2 then pcall(fs.delete, tmp) return false, err2 end
        done = done + f.size
    end
    progress("Installing", 1)
    local ok3, err3 = commit(kind, id, m, tmp)
    if not ok3 then pcall(fs.delete, tmp) return false, err3 end
    return true, m
end

function R.install(kind, id, progress)
    progress = progress or function() end
    local N = net()
    if not N then return false, "no network service" end
    progress("Reading manifest", 0)
    local m, err = call("repo.manifest", { kind = kind, id = id })
    if not m then return false, err end
    local fetch = function(f, mm)
        local parts, part, total = {}, 1, 1
        repeat
            local d, e = call("repo.file", { kind = kind, id = id, version = mm.version, path = f.path, part = part }, 12)
            if not d then return nil, "download failed: " .. f.path .. " (" .. tostring(e) .. ")" end
            parts[#parts + 1] = d.data or ""
            total = d.total or 1
            part = part + 1
        until part > total
        return table.concat(parts)
    end
    local ok, res = installFrom(kind, id, m, fetch, progress)
    if ok then return true, res.version, (kind == "os" or kind == "engine") end
    return false, res
end

-- developer direct download: baseUrl/packages/app/<id>/<version>/manifest.txt and files/<path>
function R.installDirect(baseUrl, id, version, progress)
    progress = progress or function() end
    if not http then return false, "http is not available" end
    local root = baseUrl .. "/packages/app/" .. id .. "/" .. version
    local h = http.get(root .. "/manifest.txt", nil, true)
    if not h then return false, "manifest not found" end
    local text = h.readAll()
    h.close()
    local m = textutils.unserialize(text)
    local fetch = function(f)
        local fh = http.get(root .. "/files/" .. f.path, nil, true)
        if not fh then return nil, "download failed: " .. f.path end
        local data = fh.readAll()
        fh.close()
        return data
    end
    local ok, res = installFrom("app", id, m, fetch, progress)
    if ok then return true, res.version end
    return false, res
end

function R.uninstall(id, deleteData)
    local a = appslib.find(id)
    if not a then return false, "not installed" end
    if a.system then return false, "system app" end
    local u = a.dir .. "/uninstall.lua"
    if fs.exists(u) then
        pcall(function()
            local fn = loadfile(u, "t", _ENV)
            if fn then fn() end
        end)
    end
    pcall(fs.delete, a.dir)
    if deleteData then pcall(fs.delete, "/os/data/" .. id) end
    return true
end

return R
