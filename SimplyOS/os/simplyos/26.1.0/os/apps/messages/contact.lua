-- /os/apps/messages/contact.lua
-- Contact detail page. Returns function(E, number) -> scene.
return function(E, number)
    local ui = E.ui
    local messages = dofile("/os/lib/messages.lua")
    return ui.page{
        title = function() return messages.nameOf(number) end,
        build = function()
            local c = messages.contacts()[number]
            return {
                { kind = "info", label = "Number", value = number },
                { kind = "button", label = c and "Rename" or "Save as contact", style = "primary", onTap = function()
                    E.push(ui.textEntry{ title = "Name", text = c and c.name or "", max = 24, onDone = function(name)
                        if name ~= "" then messages.setContact(number, name) end
                    end })
                end },
                c and { kind = "button", label = "Delete contact", style = "danger", onTap = function()
                    E.push(ui.confirm{ title = "Delete contact?", text = c.name, okText = "Delete", danger = true,
                        onOk = function() messages.deleteContact(number) end })
                end } or { kind = "gap" },
                { kind = "button", label = "Delete conversation", style = "danger", onTap = function()
                    E.push(ui.confirm{ title = "Delete conversation?", text = "All messages with " .. number .. " are removed from this phone.",
                        okText = "Delete", danger = true, onOk = function() messages.deleteThread(number) end })
                end },
            }
        end,
    }
end
