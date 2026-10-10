-- /os/shell/shell.lua
-- Placeholder shell for build 26.1.0: theme background and a version line.
-- Replaced by the real shell in 26.1.1.
local ctx = ...
local display, font, theme, settings = ctx.display, ctx.font, ctx.theme, ctx.settings

local function draw()
    local c = theme.colors()
    display.clear(c.bg)
    if font then
        local size, scale = font.role("caption", settings.get("display.textLevel"))
        local label = font.fit("SimplyOS " .. ctx.version.os, display.w(), size, scale)
        local w = font.width(label, size, scale)
        local h = font.height(size, scale)
        font.draw(math.floor((display.w() - w) / 2) + 1, display.h() - h - theme.scale(8), label, c.muted, c.bg, size, scale)
    end
    display.sync()
end

draw()
os.queueEvent("simplyos_shell_ready")

while true do
    local ev = os.pullEvent()
    if ev == "simplyos_redraw" then draw() end
end
