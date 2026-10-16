-- /server/source.lua
-- The only code that talks to the remote repo (sj.madefor.cc/SimplyOS). Layout: SIMPLYOS_REPO_DOC.md.
--   <base>/index.txt
--   <base>/packages/<kind>/<id>/<version>/manifest.txt
--   <base>/packages/<kind>/<id>/<version>/files/<path>
-- kind = os | engine | app. All .txt tables are textutils.serialize format, parsed with
-- textutils.unserialize (data only, no code runs).
return function(S)
    local M = {}

    M.kinds = {os = true, engine = true, app = true}

    function M.validId(id)
        return type(id) == "string" and #id <= 40 and
                   id:match("^[a-z0-9][a-z0-9_%-]*$") ~= nil
    end

    function M.validVersion(v)
        return
            type(v) == "string" and #v <= 20 and v:match("^%d+%.%d+%.%d+$") ~=
                nil
    end

    function M.validPath(p)
        if type(p) ~= "string" or #p == 0 or #p > 120 then return false end
        for seg in (p .. "/"):gmatch("([^/]*)/") do
            if seg == "" or not seg:match("^[%w_%-][%w._%-]*$") then
                return false
            end
        end
        return true
    end

    function M.parseVersion(v)
        local a, b, c = tostring(v):match("^(%d+)%.(%d+)%.(%d+)$")
        if not a then return nil end
        return {tonumber(a), tonumber(b), tonumber(c)}
    end

    -- true if version a is newer than b
    function M.newer(a, b)
        local x, y = M.parseVersion(a), M.parseVersion(b)
        if not x then return false end
        if not y then return true end
        for i = 1, 3 do if x[i] ~= y[i] then return x[i] > y[i] end end
        return false
    end

    local function base()
        return (S.config.get("repo.baseUrl"):gsub("/+$", ""))
    end

    function M.packageUrl(kind, id, ver)
        return base() .. "/packages/" .. kind .. "/" .. id .. "/" .. ver
    end

    local function hostOf(url) return url:match("^https?://([^/:]+)") end

    local function allowed(url)
        local host = hostOf(url)
        if not host then return false end
        for _, h in ipairs(S.config.get("repo.allowedHosts")) do
            if h:lower() == host:lower() then return true end
        end
        return false
    end

    -- returns body, or nil + reason
    function M.fetch(url)
        if not http then return nil, "http is disabled on this computer" end
        if not allowed(url) then
            return nil, "host not in repo.allowedHosts"
        end
        local okc, why = http.checkURL(url)
        if not okc then return nil, tostring(why) end
        local r, err, errResp = http.get({
            url = url,
            binary = true,
            timeout = S.config.get("repo.timeout")
        })
        if not r then
            local code = errResp and errResp.getResponseCode and
                             errResp.getResponseCode()
            return nil, code and ("HTTP " .. code) or tostring(err)
        end
        local code = r.getResponseCode()
        local data = r.readAll()
        r.close()
        if code ~= 200 then return nil, "HTTP " .. tostring(code) end
        if not data then return nil, "empty reply" end
        if #data > S.config.get("repo.maxBody") then
            return nil, "file too large"
        end
        return data
    end

    function M.parse(data)
        local ok, t = pcall(textutils.unserialize, data)
        if ok and type(t) == "table" then return t end
        return nil
    end

    -- remote catalogue: { format=1, packages = { {kind,id,name,latest,versions={...},note}, ... } }
    function M.index()
        local data, err = M.fetch(base() .. "/index.txt")
        if not data then return nil, err end
        local t = M.parse(data)
        if not t or t.format ~= 1 or type(t.packages) ~= "table" then
            return nil, "index.txt is not a valid format 1 index"
        end
        local out = {}
        for _, p in ipairs(t.packages) do
            if type(p) == "table" and M.kinds[p.kind] and M.validId(p.id) and
                type(p.versions) == "table" then
                local vers = {}
                for _, v in ipairs(p.versions) do
                    if M.validVersion(v) then
                        vers[#vers + 1] = v
                    end
                end
                table.sort(vers, function(a, b)
                    return M.newer(a, b)
                end) -- newest first
                out[#out + 1] = {
                    kind = p.kind,
                    id = p.id,
                    name = tostring(p.name or p.id),
                    note = tostring(p.note or ""),
                    latest = M.validVersion(p.latest) and p.latest or vers[1],
                    versions = vers
                }
            end
        end
        table.sort(out, function(a, b)
            if a.kind ~= b.kind then return a.kind < b.kind end
            return a.id < b.id
        end)
        return {fetched = S.util.now(), packages = out}
    end

    -- validated manifest of one remote version
    function M.manifest(kind, id, ver)
        local data, err =
            M.fetch(M.packageUrl(kind, id, ver) .. "/manifest.txt")
        if not data then return nil, err end
        local m = M.parse(data)
        if not m then return nil, "manifest.txt is not a table" end
        if m.format ~= 1 or m.kind ~= kind or m.id ~= id or m.version ~= ver then
            return nil,
                   "manifest does not match " .. kind .. "/" .. id .. "/" .. ver
        end
        if type(m.files) ~= "table" or #m.files == 0 then
            return nil, "manifest has no files"
        end
        local seen, maxBody = {}, S.config.get("repo.maxBody")
        for _, f in ipairs(m.files) do
            if type(f) ~= "table" or not M.validPath(f.path) then
                return nil, "bad file path in manifest"
            end
            if seen[f.path] then
                return nil, "duplicate path " .. f.path
            end
            seen[f.path] = true
            if type(f.size) ~= "number" or f.size < 0 or f.size > maxBody then
                return nil, "bad size for " .. f.path
            end
            if type(f.sha256) ~= "string" or not f.sha256:match("^%x+$") or
                #f.sha256 ~= 64 then
                return nil, "bad sha256 for " .. f.path
            end
            f.sha256 = f.sha256:lower()
        end
        if m.uninstall ~= nil and not seen[m.uninstall] then
            return nil, "uninstall file is not in files"
        end
        return m
    end

    function M.file(kind, id, ver, path)
        return M.fetch(M.packageUrl(kind, id, ver) .. "/files/" .. path)
    end

    return M
end
