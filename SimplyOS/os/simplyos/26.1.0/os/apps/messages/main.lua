-- /os/apps/messages/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui
local messages = dofile("/os/lib/messages.lua")
local simlib = dofile("/os/lib/sim.lua")

local function myNumber()
    local sim = simlib.read()
    return sim and sim.number or nil
end

local function stamp(ts)
    if not ts then return "" end
    if ts > 100000000000 then ts = math.floor(ts / 1000) end
    local ok, s = pcall(os.date, "%b %d %H:%M", ts)
    return ok and s or ""
end

local function net() return E.ctx.net end

local function startCompose(to)
    local me = myNumber()
    if not me then
        E.push(ui.notice("No SIM", "Insert a SIM disk to send messages."))
        return
    end
    E.push(ui.textEntry{ title = "To " .. messages.nameOf(to), max = 200, onDone = function(text)
        if text ~= "" then
            local id, err = messages.addOutgoing(me, to, text)
            if not id then E.toast("Could not save: " .. tostring(err)) end
        end
    end })
end

local function thread(number)
    local page
    page = ui.page{
        title = function() return messages.nameOf(number) end,
        onLoad = function() messages.markRead(number) end,
        build = function()
            local t = messages.thread(number)
            local rows = {}
            for _, m in ipairs(t.msgs) do
                rows[#rows + 1] = { kind = "bubble", dir = m.dir, text = m.body,
                    status = (m.dir == "out") and m.status or nil }
            end
            if #rows == 0 then rows[1] = { kind = "text", text = "No messages yet" } end
            return rows
        end,
        footer = {
            { label = "Reply", style = "primary", onTap = function() startCompose(number) end },
            { label = "Contact", onTap = function() E.push(dofile("/os/apps/messages/contact.lua")(E, number)) end },
        },
        event = function(self, ev)
            if ev[1] == "simplyos_msg" then
                messages.markRead(number)
                self.rebuild(true)
                self.list.top = 9999
            end
        end,
    }
    local base = page.load
    function page:load()
        base(self)
        self.list.top = 9999
    end
    return page
end

local function askNumber(onNumber)
    E.push(ui.textEntry{ title = "Number (555-0123)", max = 8, allow = "[%d%-]", onDone = function(text)
        if not text:match("^%d%d%d%-%d%d%d%d$") then
            E.push(ui.notice("Invalid number", "Use the format 555-0123."))
            return
        end
        local N = net()
        local st = N and N.state()
        if st and st.online then
            local r = N.request("who", { number = text }, 6)
            if r and r.t == "who.reply" and r.d and r.d.exists == false then
                E.push(ui.notice("Unknown number", text .. " is not registered."))
                return
            end
        end
        onNumber(text)
    end })
end

local function contactsPage()
    return ui.page{
        title = "Contacts",
        build = function()
            local rows = { { kind = "button", label = "Add contact", style = "primary", onTap = function()
                askNumber(function(number)
                    E.push(ui.textEntry{ title = "Name", max = 24, onDone = function(name)
                        if name ~= "" then messages.setContact(number, name) end
                    end })
                end)
            end } }
            local list = {}
            for number, c in pairs(messages.contacts()) do list[#list + 1] = { number = number, name = c.name or number } end
            table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
            if #list == 0 then rows[#rows + 1] = { kind = "text", text = "No contacts" } end
            for _, c in ipairs(list) do
                rows[#rows + 1] = { kind = "nav", label = c.name, value = c.number,
                    onTap = function() E.push(dofile("/os/apps/messages/contact.lua")(E, c.number)) end }
            end
            return rows
        end,
    }
end

local main
main = ui.page{
    title = "Messages",
    build = function()
        local rows = {}
        if not myNumber() then
            rows[#rows + 1] = { kind = "text", text = "No SIM. Insert a SIM disk to send and receive messages." }
        end
        rows[#rows + 1] = { kind = "button", label = "New message", style = "primary", onTap = function()
            if not myNumber() then E.push(ui.notice("No SIM", "Insert a SIM disk first.")) return end
            askNumber(function(number) E.push(thread(number)); startCompose(number) end)
        end }
        rows[#rows + 1] = { kind = "button", label = "Contacts", onTap = function() E.push(contactsPage()) end }
        local convs = messages.conversations()
        if #convs == 0 then rows[#rows + 1] = { kind = "text", text = "No conversations" } end
        for _, c in ipairs(convs) do
            rows[#rows + 1] = {
                kind = "item", title = (c.unread > 0 and "* " or "") .. c.name,
                text = (c.dir == "out" and "You: " or "") .. c.last, right = stamp(c.ts):sub(-5),
                onTap = function() E.push(thread(c.number)) end,
            }
        end
        return rows
    end,
    event = function(self, ev)
        if ev[1] == "simplyos_msg" or ev[1] == "simplyos_status" then self.rebuild(true) end
    end,
}

E.run{ id = "messages", start = main }
