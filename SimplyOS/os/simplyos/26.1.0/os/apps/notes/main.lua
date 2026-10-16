-- /os/apps/notes/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui
local fsutil = dofile("/os/lib/fsutil.lua")
local DIR = "/os/data/notes/"
local MAX = 4096

local function files()
    local out = {}
    if fs.isDir(DIR) then
        for _, f in ipairs(fs.list(DIR)) do
            if f:match("%.txt$") then out[#out + 1] = f end
        end
    end
    table.sort(out, function(a, b) return a > b end)
    return out
end

local function read(f) return fsutil.read(DIR .. f) or "" end

local function save(f, text)
    local ok, err = fsutil.safeWrite(DIR .. f, text)
    if not ok then E.toast("Could not save: " .. tostring(err)) end
    return ok
end

local function firstLine(t)
    local l = t:match("^[^\n]*") or ""
    if l == "" then l = "(empty)" end
    return l
end

local viewNote

local function editNote(f)
    E.push(ui.textEntry{ title = "Edit note", text = read(f), max = MAX, multiline = true,
        onDone = function(text) save(f, text) end })
end

viewNote = function(f)
    local page
    page = ui.page{
        title = "Note",
        build = function()
            if not fs.exists(DIR .. f) then return { { kind = "text", text = "Deleted" } } end
            return ui.textRows(read(f), "body")
        end,
        footer = {
            { label = "Edit", style = "primary", onTap = function() editNote(f) end },
            { label = "Delete", style = "danger", onTap = function()
                E.push(ui.confirm{ title = "Delete note?", text = firstLine(read(f)), okText = "Delete", danger = true,
                    onOk = function() pcall(fs.delete, DIR .. f); E.pop() end })
            end },
        },
    }
    return page
end

local main = ui.page{
    title = "Notes",
    build = function()
        local rows = { { kind = "button", label = "New note", style = "primary", onTap = function()
            E.push(ui.textEntry{ title = "New note", max = MAX, multiline = true, onDone = function(text)
                if text ~= "" then save(tostring(os.epoch("utc")) .. ".txt", text) end
            end })
        end } }
        local list = files()
        if #list == 0 then rows[#rows + 1] = { kind = "text", text = "No notes yet" } end
        for _, f in ipairs(list) do
            local t = read(f)
            local second = t:match("^[^\n]*\n([^\n]*)") or ""
            rows[#rows + 1] = { kind = "item", title = firstLine(t), text = second, onTap = function() E.push(viewNote(f)) end }
        end
        return rows
    end,
}

E.run{ id = "notes", start = main }
