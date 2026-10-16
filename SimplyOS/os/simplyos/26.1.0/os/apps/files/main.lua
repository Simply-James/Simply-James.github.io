-- /os/apps/files/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui
local fsutil = dofile("/os/lib/fsutil.lua")

local function human(n)
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.1f KB", n / 1024) end
    return n .. " B"
end

local function canDelete(path)
    if E.settings.get("dev.enabled") then return true end
    return path:sub(1, 9) == "/os/data/" and #path > 9
end

local browse

local function viewFile(path)
    return ui.page{
        title = fs.getName(path),
        build = function()
            if not fs.exists(path) then return { { kind = "text", text = "Deleted" } } end
            local size = fs.getSize(path)
            local rows = { { kind = "info", label = "Size", value = human(size) } }
            if size > 16384 then
                rows[#rows + 1] = { kind = "text", text = "Too large to view." }
            else
                local s = fsutil.read(path) or ""
                local binary = false
                for i = 1, math.min(#s, 512) do
                    local b = s:byte(i)
                    if b < 9 or (b > 13 and b < 32) then binary = true break end
                end
                if binary then rows[#rows + 1] = { kind = "text", text = "Binary file." }
                else for _, r in ipairs(ui.textRows(s, "caption")) do rows[#rows + 1] = r end end
            end
            if canDelete(path) then
                rows[#rows + 1] = { kind = "button", label = "Delete", style = "danger", onTap = function()
                    E.push(ui.confirm{ title = "Delete file?", text = path, okText = "Delete", danger = true,
                        onOk = function() pcall(fs.delete, path); E.pop() end })
                end }
            end
            return rows
        end,
    }
end

browse = function(path)
    return ui.page{
        title = path,
        build = function()
            local rows = {}
            if not fs.isDir(path) then return { { kind = "text", text = "Folder removed" } } end
            if path ~= "/" and path ~= "/os" and canDelete(path) then
                rows[#rows + 1] = { kind = "button", label = "Delete this folder", style = "danger", onTap = function()
                    E.push(ui.confirm{ title = "Delete folder?", text = path .. " (" .. human(fsutil.size(path)) .. ")",
                        okText = "Delete", danger = true, onOk = function() pcall(fs.delete, path); E.pop(); E.pop() end })
                end }
            end
            local dirs, plain = {}, {}
            for _, name in ipairs(fs.list(path)) do
                local full = fs.combine(path, name)
                if full:sub(1, 1) ~= "/" then full = "/" .. full end
                if fs.isDir(full) then dirs[#dirs + 1] = { name, full } else plain[#plain + 1] = { name, full } end
            end
            table.sort(dirs, function(a, b) return a[1] < b[1] end)
            table.sort(plain, function(a, b) return a[1] < b[1] end)
            for _, d in ipairs(dirs) do
                rows[#rows + 1] = { kind = "nav", label = d[1] .. "/", value = human(fsutil.size(d[2])),
                    onTap = function() E.push(browse(d[2])) end }
            end
            for _, f in ipairs(plain) do
                rows[#rows + 1] = { kind = "nav", label = f[1], value = human(fs.getSize(f[2])),
                    onTap = function() E.push(viewFile(f[2])) end }
            end
            if #rows == 0 then rows[1] = { kind = "text", text = "Empty" } end
            return rows
        end,
    }
end

E.run{ id = "files", start = browse(E.settings.get("dev.enabled") and "/" or "/os") }
