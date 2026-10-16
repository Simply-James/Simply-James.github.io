-- /os/apps/calculator/main.lua
local E = dofile("/os/engine/init.lua")
local ui = E.ui

local expr, shown = "", nil

local function evaluate(s)
    local pos = 1
    local function peek() return s:sub(pos, pos) end
    local expression
    local function number()
        local num = s:match("^%d*%.?%d*", pos)
        if num == "" or num == "." then error("syntax", 0) end
        pos = pos + #num
        return tonumber(num)
    end
    local function factor()
        local ch = peek()
        if ch == "-" then pos = pos + 1 return -factor() end
        if ch == "+" then pos = pos + 1 return factor() end
        if ch == "(" then
            pos = pos + 1
            local v = expression()
            if peek() ~= ")" then error("syntax", 0) end
            pos = pos + 1
            return v
        end
        return number()
    end
    local function term()
        local v = factor()
        while true do
            local ch = peek()
            if ch == "*" then pos = pos + 1; v = v * factor()
            elseif ch == "/" then
                pos = pos + 1
                local d = factor()
                if d == 0 then error("divide by zero", 0) end
                v = v / d
            else return v end
        end
    end
    expression = function()
        local v = term()
        while true do
            local ch = peek()
            if ch == "+" then pos = pos + 1; v = v + term()
            elseif ch == "-" then pos = pos + 1; v = v - term()
            else return v end
        end
    end
    local v = expression()
    if pos <= #s then error("syntax", 0) end
    return v
end

local function fmt(v)
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.10g", v)
end

local KEYS = {
    { "C", "(", ")", "/" },
    { "7", "8", "9", "*" },
    { "4", "5", "6", "-" },
    { "1", "2", "3", "+" },
    { "0", ".", "<-", "=" },
}

local function press(k)
    if k == "C" then expr, shown = "", nil
    elseif k == "<-" then expr = expr:sub(1, -2); shown = nil
    elseif k == "=" then
        if expr ~= "" then
            local ok, v = pcall(evaluate, expr)
            if ok then expr = fmt(v); shown = nil else shown = "Error: " .. tostring(v) end
        end
    else
        if #expr < 40 then expr = expr .. k; shown = nil end
    end
end

local buttons = {}
for r, row in ipairs(KEYS) do
    for c, k in ipairs(row) do
        local style = (k == "=") and "primary" or nil
        buttons[#buttons + 1] = { b = ui.button{ label = k, style = style, onTap = function() press(k) end }, r = r, c = c }
    end
end

local scene = E.scene{}
scene.widgets = {}
for _, x in ipairs(buttons) do scene.widgets[#scene.widgets + 1] = x.b end

function scene:drawUI(g)
    local m, c = E.m, E.c
    local dispH = math.floor(E.h * 0.28)
    local text = shown or expr
    if text == "" then text = "0" end
    local lvl = 4
    while lvl > 1 and g.textWidth(text, lvl) > E.w - 2 * m.pad do lvl = lvl - 1 end
    g.text(E.w - m.pad - g.textWidth(text, lvl), dispH - g.lineHeight(lvl) - m.pad, text, lvl, shown and 0xFFFF7070 or c.text, c.bg)
    local gap = 4
    local kh = math.floor((E.h - dispH - m.pad - gap * 4) / 5)
    local kw = math.floor((E.w - 2 * m.pad - gap * 3) / 4)
    for _, x in ipairs(buttons) do
        x.b:setRect(m.pad + (x.c - 1) * (kw + gap), dispH + (x.r - 1) * (kh + gap), kw, kh)
    end
end

E.run{ id = "calculator", start = scene }
