-- /os/lib/theme.lua
-- Colours and metrics. Reads settings on every call.
local settings = dofile("/os/lib/settings.lua")

local M = {}

local ACCENTS = { jblue = 0xFF0022FF, jpink = 0xFFD400FF, jpurple = 0xFF6A11FF }

local DARK = { bg = 0xFF000000, card = 0xFF1B1B1F, raised = 0xFF26262B, text = 0xFFEDEDF2, muted = 0xFF9A9AA6 }
local LIGHT = { bg = 0xFFF2F2F7, card = 0xFFFFFFFF, raised = 0xFFE6E6EC, text = 0xFF111114, muted = 0xFF6B6B76 }

function M.colors()
    local base = settings.get("display.theme") == "light" and LIGHT or DARK
    local c = {}
    for k, v in pairs(base) do c[k] = v end
    c.accent = ACCENTS[settings.get("display.accent")] or ACCENTS.jblue
    c.onAccent = 0xFFFFFFFF
    return c
end

function M.scale(n)
    return math.floor(n * settings.get("display.uiScale") / 100 + 0.5)
end

function M.metrics()
    local s = M.scale
    return {
        statusBar = s(28),
        navBar = math.max(s(44), 44),
        pad = s(12),
        radius = s(16),
        row = s(48),
        target = math.max(s(44), 44),
    }
end

return M
