-- /server/admin.lua
-- Terminal menus: Status, Subscribers, Issue SIM, Storage, Mail, App manager, Backup, Broadcast, Logs, Config.
return function(S)
    local M = {}

    local function colorOn() return term.isColor and term.isColor() end
    local function color(c) if colorOn() then term.setTextColor(c) end end

    local function head(title)
        term.clear()
        term.setCursorPos(1, 1)
        color(colors.yellow)
        print("SimplyOS Root Server " .. S.version)
        color(colors.white)
        print(title)
        print(string.rep("-", (term.getSize())))
    end

    local function pause()
        color(colors.lightGray)
        write("Enter to go back ")
        color(colors.white)
        read()
    end

    local function ask(prompt)
        write(prompt)
        return read() or ""
    end

    local function yn(prompt) return ask(prompt .. " (y/n) "):lower() == "y" end

    local function warn(text)
        color(colors.orange)
        print(text)
        color(colors.white)
    end

    local function fit(s) return s:sub(1, (term.getSize())) end

    -- page through items; returns the chosen index or nil. fmt(item) -> line
    local function pick(title, items, fmt)
        local page = 1
        while true do
            head(title)
            local _, h = term.getSize()
            local per = math.max(3, h - 8)
            local pages = math.max(1, math.ceil(#items / per))
            page = math.min(page, pages)
            for i = (page - 1) * per + 1, math.min(#items, page * per) do
                print(fit(i .. "  " .. fmt(items[i])))
            end
            if #items == 0 then print("(none)") end
            print("")
            print("page " .. page .. "/" .. pages ..
                      "   number = select, n/p = page, b = back")
            local c = ask("> "):lower()
            if c == "b" or c == "" and #items == 0 then return nil end
            if c == "n" then
                page = math.min(pages, page + 1)
            elseif c == "p" then
                page = math.max(1, page - 1)
            elseif tonumber(c) and items[tonumber(c)] then
                return tonumber(c)
            end
        end
    end

    local function ago(t)
        if not t or t == 0 then return "never" end
        return S.util.duration(S.util.now() - t) .. " ago"
    end

    -- Status --------------------------------------------------------------
    local function status()
        head("Status")
        local cfg = S.config.get
        local n = S.net.status()
        print("Uptime: " ..
                  S.util.duration((os.epoch("utc") - S.startMs) / 1000))
        print(
            "Host: " .. cfg("server.hostname") .. " (" .. cfg("net.protocol") ..
                "), computer " .. os.getComputerID())
        print("Modem: " .. (n.modem or "none, searching") .. "   rx " .. n.rx ..
                  " tx " .. n.tx .. " bad " .. n.bad)
        local sess = S.auth.list()
        print("Logged in: " .. #sess .. "   Subscribers: " ..
                  S.subscribers.count())
        for i = 1, math.min(5, #sess) do
            local s = sess[i]
            print("  " .. s.number .. "  computer " .. s.id .. "  last " ..
                      ago(s.last))
        end
        local _, total = S.mail.queues()
        print("Pending messages: " .. total)
        local st = S.storage.totals()
        print("Storage: " .. st.count .. " disks, " .. S.util.bytes(st.free) ..
                  " free of " .. S.util.bytes(st.cap))
        local cap, free = fs.getCapacity("/"), fs.getFreeSpace("/")
        print("Main disk: " .. S.util.bytes(cap - free) .. " used, " ..
                  S.util.bytes(free) .. " free")
        print("SIM drive: " ..
                  (#S.storage.sims > 0 and "disk ready" or "no disk"))
        print("Crypto: " .. S.crypto.describe())
        local admins = 0
        for _, e in ipairs(S.subscribers.list()) do
            if e.rec.admin then admins = admins + 1 end
        end
        local serving = 0
        for _, p in ipairs(S.repo.list()) do
            if p.enabled then serving = serving + 1 end
        end
        print("Admin phones: " .. admins .. "   Packages served: " .. serving)
        local b = S.backup.info()
        print("Backup: floppy " ..
                  (b.lastExport and ago(b.lastExport) or "NEVER") .. ", local " ..
                  (b.lastLocal and ago(b.lastLocal) or "none"))
        if not b.lastExport or S.util.now() - b.lastExport >
            S.config.get("backup.warnDays") * 86400 then
            warn("Floppy backup is overdue (menu 7)")
        end
        if S.subscribers.secretBad then
            warn("SECRET FILE UNREADABLE: logins disabled")
        end
        local rec = S.log.recent(4)
        if #rec > 0 then
            warn("Recent problems:")
            for _, l in ipairs(rec) do print(fit(l)) end
        end
        pause()
    end

    -- Subscribers ---------------------------------------------------------
    local function subscriberMenu(number)
        while true do
            local r = S.subscribers.get(number)
            if not r then return end
            head("Subscriber " .. number)
            print("Status: " .. r.status)
            print("Issued: " .. S.util.stamp(r.issued) .. " UTC")
            print("Last seen: " .. ago(r.lastSeen))
            print("Note: " .. (r.note ~= "" and r.note or "-"))
            print("Admin phone: " .. (r.admin and "YES" or "no"))
            print("")
            print("s suspend   a activate   r revoke")
            print("n note      m admin on/off")
            print("d delete    b back")
            local c = ask("> "):lower()
            if c == "s" then
                S.subscribers.setStatus(number, "suspended")
            elseif c == "a" then
                S.subscribers.setStatus(number, "active")
            elseif c == "r" then
                if yn("Revoke " .. number .. "?") then
                    S.subscribers.setStatus(number, "revoked")
                end
            elseif c == "n" then
                S.subscribers.setNote(number, ask("Note: "))
            elseif c == "m" then
                local want = not r.admin
                if yn((want and "Make " or "Remove admin from ") .. number ..
                          (want and " an admin phone?" or "?")) then
                    S.subscribers.setAdmin(number, want)
                    S.log.info("admin", "terminal: admin " .. tostring(want) ..
                                   " for " .. number)
                end
            elseif c == "d" then
                if yn("Delete " .. number .. " for good?") then
                    if yn("Also purge its pending mail?") then
                        S.mail.purge(number)
                    end
                    S.subscribers.remove(number)
                    return
                end
            elseif c == "b" then
                return
            end
        end
    end

    local function subscribers()
        while true do
            local list = S.subscribers.list()
            local i = pick("Subscribers (" .. #list .. ")", list, function(e)
                return e.number .. "  " .. e.rec.status ..
                           (e.rec.admin and "  ADMIN" or "") .. "  " ..
                           ago(e.rec.lastSeen)
            end)
            if not i then return end
            subscriberMenu(list[i].number)
        end
    end

    -- Issue SIM -----------------------------------------------------------
    local function issueSim()
        head("Issue SIM")
        S.storage.scan()
        local sims = S.storage.sims
        if #sims == 0 then
            print("No SIM disk found.")
            print("Put a floppy into the SIM drive (any drive")
            print("that does not hold a Storage_ disk).")
            pause()
            return
        end
        local d = sims[1]
        if #sims > 1 then
            local i = pick("Which SIM disk?", sims, function(x)
                return x.drive .. "  label " .. tostring(x.label)
            end)
            if not i then return end
            d = sims[i]
        end
        if not d.mount then
            print("That disk cannot hold files.")
            pause()
            return
        end
        print("Drive " .. d.drive .. ", label " .. tostring(d.label or "-"))

        local files = fs.list(d.mount)
        if #files > 0 then
            warn("The disk has " .. #files .. " files on it.")
            if not yn("Erase it and use it as a SIM?") then return end
            for _, f in ipairs(files) do
                fs.delete(fs.combine(d.mount, f))
            end
        end

        local number = ask("Number (empty = generate): ")
        if number == "" then
            number = S.subscribers.newNumber()
            if not number then
                print("No free numbers.")
                pause()
                return
            end
        elseif not S.subscribers.valid(number) then
            print("Format is NNN-NNNN.")
            pause()
            return
        elseif S.subscribers.get(number) then
            print("That number is taken.")
            pause()
            return
        end
        local note = ask("Note (optional): ")
        local makeAdmin =
            yn("Admin phone? (can use admin tools from the phone)")

        local imsi = S.subscribers.newImsi()
        local sim = {
            number = number,
            imsi = imsi,
            key = S.subscribers.deriveKey(number, imsi),
            server = S.config.get("server.hostname"),
            issued = S.util.now()
        }
        local path = fs.combine(d.mount, "sim.lua")
        local f = fs.open(path, "w")
        if not f then
            print("Cannot write to the disk.")
            pause()
            return
        end
        f.write("return " .. textutils.serialize(sim))
        f.close()
        pcall(disk.setLabel, d.drive, number)

        -- read back and compare
        local okRead, got = pcall(function()
            local fn = loadfile(path, "t", {})
            return fn and fn()
        end)
        local good =
            okRead and type(got) == "table" and disk.getLabel(d.drive) == number
        if good then
            for k, v in pairs(sim) do
                if got[k] ~= v then good = false end
            end
        end
        if not good then
            pcall(fs.delete, path)
            warn("Read back did not match. SIM not issued.")
            pause()
            return
        end
        local ok, why = S.subscribers.create(number, imsi, note, makeAdmin)
        if not ok then
            pcall(fs.delete, path)
            warn("Could not save the subscriber: " .. tostring(why))
            pause()
            return
        end
        S.log.info("admin", "issued SIM " .. number)
        color(colors.lime)
        print("SIM " .. number .. " issued and verified.")
        color(colors.white)
        print("Take the floppy out of the drive.")
        pause()
    end

    -- Storage -------------------------------------------------------------
    local function storage()
        S.storage.scan()
        head("Storage")
        local vols = S.storage.volumes()
        if #vols == 0 then
            warn("No Storage_ disks. Using the main disk.")
        end
        for _, v in ipairs(vols) do
            local used = v.cap - v.free
            local pct = v.cap > 0 and math.floor(used * 100 / v.cap) or 0
            print(fit(
                      v.label .. "  " .. v.drive .. "  " .. S.util.bytes(used) ..
                          "/" .. S.util.bytes(v.cap) .. "  " .. pct .. "%"))
        end
        local st = S.storage.totals()
        print("")
        print("Total: " .. st.count .. " disks, " .. S.util.bytes(st.free) ..
                  " free of " .. S.util.bytes(st.cap))
        local cap, free = fs.getCapacity("/"), fs.getFreeSpace("/")
        print("Main disk: " .. S.util.bytes(free) .. " free of " ..
                  S.util.bytes(cap))
        print("SIM disks: " .. #S.storage.sims)
        print("")
        print("Disks labeled Storage_<x> are used automatically.")
        pause()
    end

    -- Mail ----------------------------------------------------------------
    local function mail()
        while true do
            head("Mail")
            local q, total = S.mail.queues()
            print("Pending: " .. total .. " in " .. #q .. " mailboxes")
            for i = 1, math.min(8, #q) do
                print("  " .. q[i].number .. "  " .. q[i].count .. " msgs  " ..
                          S.util.bytes(q[i].bytes))
            end
            print("")
            print("p purge one mailbox   e purge expired   b back")
            local c = ask("> "):lower()
            if c == "p" then
                local n = ask("Number: ")
                if S.subscribers.valid(n) and yn("Purge mail for " .. n .. "?") then
                    print("Removed " .. S.mail.purge(n))
                    sleep(1)
                end
            elseif c == "e" then
                print("Expired " .. S.mail.sweep())
                sleep(1)
            elseif c == "b" then
                return
            end
        end
    end

    -- helpers for disks ---------------------------------------------------------
    local function pickDisk(title)
        S.storage.scan()
        local sims = S.storage.sims
        if #sims == 0 then
            print("No floppy found in the SIM drive.")
            pause()
            return nil
        end
        local d = sims[1]
        if #sims > 1 then
            local i = pick(title, sims, function(x)
                return x.drive .. "  label " .. tostring(x.label)
            end)
            if not i then return nil end
            d = sims[i]
        end
        if not d.mount then
            print("That disk cannot hold files.")
            pause()
            return nil
        end
        return d
    end

    local function askSecret(prompt)
        write(prompt)
        return read("*") or ""
    end

    -- App manager -----------------------------------------------------------------
    local function runMirror(kind, id, ver)
        local p = S.repo.get(kind, id)
        if p and p.versions[ver] and p.versions[ver].mirrored then
            if not yn("Already on the server. Download again (loses edits)?") then
                return
            end
        end
        print("")
        local ok, why = S.repo.mirror(kind, id, ver,
                                      function(line) print(fit(line)) end)
        if ok then
            color(colors.lime)
            print("Done. Open Hosted packages to edit it and turn it on.")
            color(colors.white)
        else
            warn("Failed: " .. tostring(why))
        end
        pause()
    end

    local function browseRemote()
        head("Remote repo")
        print(S.config.get("repo.baseUrl"))
        print("fetching index...")
        local ok, why = S.repo.refreshRemote()
        if not ok then
            warn("Failed: " .. tostring(why))
            pause()
            return
        end
        while true do
            local list = S.repo.remote().packages
            local i = pick("Remote packages (" .. #list .. ")", list,
                           function(p)
                local mine = S.repo.get(p.kind, p.id)
                return p.kind .. ":" .. p.id .. "  " .. tostring(p.latest) ..
                           "  (" .. #p.versions .. " versions)" ..
                           (mine and "  *" or "")
            end)
            if not i then return end
            local p = list[i]
            while true do
                local j = pick(p.kind .. ":" .. p.id ..
                                   " versions  (* = on this server)",
                               p.versions, function(v)
                    local mine = S.repo.get(p.kind, p.id)
                    local info = mine and mine.versions[v]
                    return v .. (info and info.mirrored and "  *" or "")
                end)
                if not j then break end
                runMirror(p.kind, p.id, p.versions[j])
            end
        end
    end

    local function editFile(kind, id, ver, path)
        local rel = S.repo.filePath(kind, id, ver, path)
        local full = S.storage.pathFor(rel)
        pcall(function()
            local dir = fs.getDir(full)
            if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        end)
        if not shell then
            warn("The editor needs the shell.")
            pause()
            return
        end
        shell.run("edit", full)
        local ok, why = S.repo.rehash(kind, id, ver)
        head("Edited " .. path)
        print(ok and "Hashes updated. The version is now marked modified." or
                  ("Rehash failed: " .. tostring(why)))
        pause()
    end

    local function versionMenu(kind, id, ver)
        while true do
            local p = S.repo.get(kind, id)
            local v = p and p.versions[ver]
            if not v then return end
            head(kind .. ":" .. id .. " " .. ver)
            print("Name: " .. p.name)
            print("Files: " .. v.files .. "   Size: " .. S.util.bytes(v.size))
            print("Mirrored " .. ago(v.at) ..
                      (v.modified and "   MODIFIED" or ""))
            print("Approved: " .. (v.approved and "yes" or "no"))
            print("Serving: " ..
                      ((p.enabled and p.active == ver) and "YES" or "no"))
            print("")
            print("e serve this version   f edit a file")
            print("n new file             l list files")
            print("h rehash               a approved on/off")
            print("s stop serving package  x delete version")
            print("b back")
            local c = ask("> "):lower()
            if c == "e" then
                local ok, why = S.repo.setActive(kind, id, ver)
                if not ok then
                    warn(tostring(why))
                    pause()
                end
            elseif c == "f" then
                local files = S.repo.files(kind, id, ver)
                local i = pick("Edit which file?", files,
                               function(x) return x end)
                if i then editFile(kind, id, ver, files[i]) end
            elseif c == "n" then
                local path = ask("New file path (e.g. lib/extra.lua): ")
                if S.source.validPath(path) then
                    editFile(kind, id, ver, path)
                else
                    warn("Bad path.")
                    pause()
                end
            elseif c == "l" then
                head("Files")
                for _, f in ipairs(S.repo.files(kind, id, ver)) do
                    print(fit(f))
                end
                pause()
            elseif c == "h" then
                local ok, why = S.repo.rehash(kind, id, ver)
                print(ok and "Done." or tostring(why))
                sleep(1)
            elseif c == "a" then
                S.repo.setApproved(kind, id, ver, not v.approved)
            elseif c == "s" then
                S.repo.disable(kind, id)
            elseif c == "x" then
                if yn("Delete " .. ver .. " from this server?") then
                    S.repo.deleteVersion(kind, id, ver)
                    return
                end
            elseif c == "b" then
                return
            end
        end
    end

    local function packageMenu(kind, id)
        while true do
            local p = S.repo.get(kind, id)
            if not p then return end
            local vers = S.repo.sortedVersions(p)
            local i = pick(kind .. ":" .. id .. "  " .. p.name .. "  (" ..
                               (p.enabled and ("serving " .. tostring(p.active)) or
                                   "not served") .. ")  d = stop serving", vers,
                           function(v)
                local info = p.versions[v]
                return v .. (info.mirrored and "" or "  MISSING") ..
                           (info.modified and "  modified" or "") ..
                           ((p.enabled and p.active == v) and "  SERVING" or "")
            end)
            if not i then return end
            versionMenu(kind, id, vers[i])
        end
    end

    local function hosted()
        while true do
            local list = S.repo.list()
            head("Hosted packages")
            local i = pick("Hosted packages (" .. #list .. ")", list,
                           function(p)
                return p.kind .. ":" .. p.id .. "  " ..
                           (p.enabled and ("serving " .. tostring(p.active)) or
                               "off")
            end)
            if not i then return end
            packageMenu(list[i].kind, list[i].id)
        end
    end

    local function appManager()
        while true do
            head("App manager")
            print("Remote: " .. S.config.get("repo.baseUrl"))
            print("")
            print("1  Browse remote repo and download a version")
            print("2  Hosted packages (edit, serve, stop serving)")
            print("b  Back")
            local c = ask("> "):lower()
            if c == "1" then
                browseRemote()
            elseif c == "2" then
                hosted()
            elseif c == "b" then
                return
            end
        end
    end

    -- Backup ----------------------------------------------------------------------
    local function backupExport()
        head("Backup to floppy")
        print("The backup holds the master secret (every SIM key).")
        print("Keep the floppy away from the server.")
        print("")
        local d = pickDisk("Which disk?")
        if not d then return end
        if fs.exists(fs.combine(d.mount, "sim.lua")) then
            warn("That floppy is a SIM. Use another.")
            pause()
            return
        end
        local files = fs.list(d.mount)
        if #files > 0 then
            warn("The disk has " .. #files .. " files.")
            if not yn("Erase it and use it for the backup?") then
                return
            end
            for _, f in ipairs(files) do
                fs.delete(fs.combine(d.mount, f))
            end
        end
        local pass = askSecret("Passphrase (empty = none): ")
        if pass ~= "" and askSecret("Again: ") ~= pass then
            warn("Does not match.")
            pause()
            return
        end
        print("working...")
        local ok, why = S.backup.exportToDisk(d, pass)
        if ok then
            color(colors.lime)
            print("Backup written and verified. Take the floppy out.")
            color(colors.white)
        else
            warn("Failed: " .. tostring(why))
        end
        pause()
    end

    local function doRestore(file, label)
        local pass = ""
        if S.backup.isEncrypted(file) then
            pass = askSecret("Passphrase: ")
        end
        warn(
            "This REPLACES the secret, subscribers, config and app manager state.")
        if ask("Type RESTORE to continue: ") ~= "RESTORE" then return end
        print("working...")
        local ok, why = S.backup.restore(file, pass)
        if not ok then
            warn("Failed: " .. tostring(why))
            pause()
            return
        end
        color(colors.lime)
        print("Restored from " .. label .. ". Restarting the server.")
        color(colors.white)
        sleep(2)
        os.reboot()
    end

    local function backupMenu()
        while true do
            head("Backup")
            local b = S.backup.info()
            print("Floppy: " .. (b.lastExport and ago(b.lastExport) or "never"))
            print("Local copy (storage disks): " ..
                      (b.lastLocal and ago(b.lastLocal) or "none"))
            print("")
            print("1  Export to floppy")
            print("2  Write the local copy now")
            print("3  Restore from floppy")
            print("4  Restore from local copy")
            print("b  Back")
            local c = ask("> "):lower()
            if c == "1" then
                backupExport()
            elseif c == "2" then
                local ok, why = S.backup.writeLocal()
                print(ok and "Written." or ("Failed: " .. tostring(why)))
                sleep(1)
            elseif c == "3" then
                head("Restore from floppy")
                local d = pickDisk("Which disk?")
                if d then
                    local file = S.backup.readDisk(d.mount)
                    if file then
                        doRestore(file, "the floppy")
                    else
                        warn("No backup.lua on that disk.")
                        pause()
                    end
                end
            elseif c == "4" then
                local file = S.backup.readLocal()
                if file then
                    doRestore(file, "the local copy")
                else
                    warn("No local copy found.")
                    pause()
                end
            elseif c == "b" then
                return
            end
        end
    end

    -- Broadcast -------------------------------------------------------------------
    local function broadcast()
        head("Broadcast notification")
        print("Sent to every phone logged in now, and to the rest")
        print("when they log in (phones can turn these off).")
        print("")
        local title = ask("Title: ")
        local text = ask("Text: ")
        if text == "" then return end
        if not yn("Send?") then return end
        local id, sent = S.push.broadcast({
            title = title ~= "" and title or "Notice",
            text = text
        })
        print("Sent #" .. id .. " to " .. sent .. " phones now.")
        pause()
    end

    -- Logs ----------------------------------------------------------------
    local function logs()
        head("Log (last lines)")
        local _, h = term.getSize()
        for _, l in ipairs(S.log.tail(h - 6)) do print(fit(l)) end
        pause()
    end

    -- Config --------------------------------------------------------------
    local function config()
        while true do
            local keys = S.config.keys()
            local i = pick("Config", keys, function(k)
                local v = S.config.get(k)
                return k .. " = " ..
                           (type(v) == "table" and "{...}" or tostring(v))
            end)
            if not i then return end
            local k = keys[i]
            local cur = S.config.get(k)
            if type(cur) == "table" then
                warn("Edit /server/data/config.lua by hand for lists.")
                pause()
            else
                local raw = ask(k .. " [" .. tostring(cur) ..
                                    "] new value (empty = cancel, d = default): ")
                if raw == "d" then
                    S.config.reset(k)
                elseif raw ~= "" then
                    local v = raw
                    if type(cur) == "number" then
                        v = tonumber(raw)
                    elseif type(cur) == "boolean" then
                        v = (raw == "true") and true or (raw == "false") and
                                false or nil
                    end
                    local ok, why = false, "bad value"
                    if v ~= nil then
                        ok, why = S.config.set(k, v)
                    end
                    if not ok then
                        warn("Not saved: " .. tostring(why))
                        pause()
                    end
                end
            end
        end
    end

    function M.run()
        while true do
            head("Main menu")
            print("1  Status")
            print("2  Subscribers")
            print("3  Issue SIM")
            print("4  Storage")
            print("5  Mail")
            print("6  App manager")
            print("7  Backup")
            print("8  Broadcast notification")
            print("9  Logs")
            print("c  Config")
            print("q  Quit server")
            local c = ask("> "):lower()
            if c == "1" then
                status()
            elseif c == "2" then
                subscribers()
            elseif c == "3" then
                issueSim()
            elseif c == "4" then
                storage()
            elseif c == "5" then
                mail()
            elseif c == "6" then
                appManager()
            elseif c == "7" then
                backupMenu()
            elseif c == "8" then
                broadcast()
            elseif c == "9" then
                logs()
            elseif c == "c" then
                config()
            elseif c == "q" then
                S.log.info("admin", "quit from terminal")
                S.stop()
                return
            end
        end
    end

    return M
end
