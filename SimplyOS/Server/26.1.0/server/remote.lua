-- /server/remote.lua
-- Admin over the network. Only a logged-in session of a subscriber with admin = true (set on the
-- server terminal, Subscribers menu) may use these, and only while config admin.remote is on.
-- Not available remotely, on purpose: issuing SIMs, deleting subscribers, promoting admins, config,
-- backup and restore, editing app files, mirroring from the remote repo.
-- Every call is logged with the admin's number.
-- Packets (all session + admin): admin.status, admin.subs, admin.sub.set, admin.mail,
-- admin.mail.purge, admin.repo, admin.repo.enable, admin.repo.disable, admin.push, admin.log
return function(S)
    local M = {}
    local on = function(t, fn) S.net.on(t, fn, {admin = true}) end

    local function audit(s, text)
        S.log.info("admin", s.number .. " " .. text)
    end

    on("admin.status", function(id, msg, d, s)
        local _, pending = S.mail.queues()
        local st = S.storage.totals()
        local n = S.net.status()
        S.net.send(id, "admin.status.reply", msg.rid, {
            version = S.version,
            uptime = math.floor((os.epoch("utc") - S.startMs) / 1000),
            subscribers = S.subscribers.count(),
            loggedIn = #S.auth.list(),
            computers = #n.peers,
            pending = pending,
            disks = st.count,
            storageFree = st.free,
            storageCap = st.cap,
            mainFree = fs.getFreeSpace("/"),
            mainCap = fs.getCapacity("/"),
            problems = S.log.recent(3)
        })
    end)

    on("admin.subs", function(id, msg, d)
        local list = S.subscribers.list()
        local per = 15
        local pages = math.max(1, math.ceil(#list / per))
        local page = math.min(math.max(1, tonumber(d.page) or 1), pages)
        local out = {}
        for i = (page - 1) * per + 1, math.min(#list, page * per) do
            local e = list[i]
            out[#out + 1] = {
                number = e.number,
                status = e.rec.status,
                admin = e.rec.admin or false,
                lastSeen = e.rec.lastSeen or 0,
                note = e.rec.note or ""
            }
        end
        S.net.send(id, "admin.subs.reply", msg.rid,
                   {items = out, page = page, pages = pages})
    end)

    -- {number, status = active|suspended|revoked, note = text}. Admin accounts cannot be changed here.
    on("admin.sub.set", function(id, msg, d, s)
        local rec = S.subscribers.valid(d.number) and
                        S.subscribers.get(d.number)
        if not rec then
            S.net.err(id, msg, "notfound", "no such number")
            return
        end
        if rec.admin then
            S.net.err(id, msg, "auth",
                      "admin accounts are changed on the server")
            return
        end
        if d.status ~= nil then
            if d.status ~= "active" and d.status ~= "suspended" and d.status ~=
                "revoked" then
                S.net.err(id, msg, "unknown", "bad status")
                return
            end
            S.subscribers.setStatus(d.number, d.status)
            audit(s, "set " .. d.number .. " " .. d.status)
        end
        if type(d.note) == "string" then
            S.subscribers.setNote(d.number, d.note:sub(1, 60))
            audit(s, "note on " .. d.number)
        end
        S.net.send(id, "admin.sub.set.reply", msg.rid, {
            number = d.number,
            status = S.subscribers.get(d.number).status
        })
    end)

    on("admin.mail", function(id, msg)
        local q, total = S.mail.queues()
        S.net.send(id, "admin.mail.reply", msg.rid, {queues = q, total = total})
    end)

    on("admin.mail.purge", function(id, msg, d, s)
        if not S.subscribers.valid(d.number) then
            S.net.err(id, msg, "unknown", "bad number")
            return
        end
        local n = S.mail.purge(d.number)
        audit(s, "purged mail of " .. d.number .. " (" .. n .. ")")
        S.net.send(id, "admin.mail.purge.reply", msg.rid,
                   {number = d.number, removed = n})
    end)

    on("admin.repo", function(id, msg)
        local out = {}
        for _, p in ipairs(S.repo.list()) do
            local vers = {}
            for _, v in ipairs(S.repo.sortedVersions(p)) do
                local info = p.versions[v]
                vers[#vers + 1] = {
                    version = v,
                    mirrored = info.mirrored,
                    modified = info.modified,
                    approved = info.approved
                }
            end
            out[#out + 1] = {
                kind = p.kind,
                id = p.id,
                name = p.name,
                active = p.active,
                enabled = p.enabled,
                versions = vers
            }
        end
        S.net.send(id, "admin.repo.reply", msg.rid, {packages = out})
    end)

    on("admin.repo.enable", function(id, msg, d, s)
        if not S.source.kinds[d.kind] or not S.source.validId(d.id) or
            not S.source.validVersion(d.version) then
            S.net.err(id, msg, "unknown", "bad package")
            return
        end
        local ok, why = S.repo.setActive(d.kind, d.id, d.version)
        if not ok then
            S.net.err(id, msg, "notfound", tostring(why))
            return
        end
        audit(s, "enabled " .. d.kind .. ":" .. d.id .. " " .. d.version)
        S.net.send(id, "admin.repo.enable.reply", msg.rid,
                   {kind = d.kind, id = d.id, version = d.version})
    end)

    on("admin.repo.disable", function(id, msg, d, s)
        if not S.source.kinds[d.kind] or not S.source.validId(d.id) then
            S.net.err(id, msg, "unknown", "bad package")
            return
        end
        S.repo.disable(d.kind, d.id)
        audit(s, "disabled " .. d.kind .. ":" .. d.id)
        S.net.send(id, "admin.repo.disable.reply", msg.rid,
                   {kind = d.kind, id = d.id})
    end)

    on("admin.push", function(id, msg, d, s)
        if type(d.text) ~= "string" or #d.text == 0 then
            S.net.err(id, msg, "unknown", "text needed")
            return
        end
        local pid, sent = S.push.broadcast({
            title = d.title or "Notice",
            text = d.text
        })
        audit(s, "broadcast #" .. pid)
        S.net.send(id, "admin.push.reply", msg.rid, {id = pid, sent = sent})
    end)

    on("admin.log", function(id, msg, d)
        local n = math.min(30, math.max(1, tonumber(d.lines) or 10))
        S.net.send(id, "admin.log.reply", msg.rid, {lines = S.log.tail(n)})
    end)

    return M
end
