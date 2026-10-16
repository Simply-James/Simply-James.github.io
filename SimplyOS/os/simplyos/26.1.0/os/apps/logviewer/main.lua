-- /os/apps/logviewer/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui
local fsutil = dofile("/os/lib/fsutil.lua")

local function logs()
    local out = {}
    if fs.isDir("/os/logs") then
        for _, f in ipairs(fs.list("/os/logs")) do
            local p = "/os/logs/" .. f
            if not fs.isDir(p) then
                local t = 0
                pcall(function() t = fs.attributes(p).modified or 0 end)
                out[#out + 1] = { name = f, path = p, t = t }
            end
        end
    end
    table.sort(out, function(a, b) if a.t ~= b.t then return a.t > b.t end return a.name < b.name end)
    return out
end

local function view(path)
    return ui.page{
        title = fs.getName(path),
        build = function()
            local s = fsutil.read(path) or ""
            if #s > 8000 then s = s:sub(-8000) end
            local lines = {}
            for ln in s:gmatch("[^\n]+") do table.insert(lines, 1, ln) end   -- newest first
            if #lines == 0 then return { { kind = "text", text = "Empty" } } end
            return ui.textRows(table.concat(lines, "\n"), "caption")
        end,
    }
end

local main = ui.page{
    title = "Logs",
    build = function()
        local rows = { { kind = "button", label = "Clear all logs", style = "danger", onTap = function()
            E.push(ui.confirm{ title = "Clear logs?", text = "Deletes every file in /os/logs.", okText = "Clear", danger = true,
                onOk = function()
                    for _, l in ipairs(logs()) do pcall(fs.delete, l.path) end
                    E.pop()
                end })
        end } }
        local list = logs()
        if #list == 0 then rows[#rows + 1] = { kind = "text", text = "No logs" } end
        for _, l in ipairs(list) do
            rows[#rows + 1] = { kind = "nav", label = l.name, value = fs.getSize(l.path) .. " B",
                onTap = function() E.push(view(l.path)) end }
        end
        return rows
    end,
}

E.run{ id = "logviewer", start = main }
