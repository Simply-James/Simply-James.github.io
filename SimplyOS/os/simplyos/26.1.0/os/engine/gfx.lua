-- /os/engine/gfx.lua
-- Safe 2D drawing in a view (offset + clip), text roles, rounded rectangles, icons.
-- local g = gfx.new(ctx); g.setView(ox, oy, w, h); g.rect / g.text / g.roundRect ...
local M = {}

local insetCache = {}
local iconCache = {}
local signedFlag

local function insetsFor(r)
    if not insetCache[r] then
        local t = {}
        for i = 0, r - 1 do
            local dy = r - i - 0.5
            t[i] = math.ceil(r - math.sqrt(r * r - dy * dy))
        end
        insetCache[r] = t
    end
    return insetCache[r]
end

function M.loadPng(gpu, path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local data = f.readAll()
    f.close()
    local buf = gpu.newBuffer(#data)
    for i = 1, #data, 2048 do buf.write(string.byte(data, i, math.min(i + 2047, #data))) end
    local img = gpu.decodeImage(buf.ref())
    buf.free()
    return img
end

local function isSigned(gpu)
    if signedFlag == nil then
        signedFlag = true
        pcall(function()
            local im = gpu.newImage(1, 1)
            im.setRGB(1, 1, 0xFFFF0000)
            local v = tonumber((im.getAsBuffer()))
            if v then signedFlag = v < 0 end
            pcall(im.free)
        end)
    end
    return signedFlag
end

local function toRGBA(v)
    if v < 0 then v = v + 4294967296 end
    return math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256, math.floor(v / 16777216)
end
M.toRGBA = toRGBA

-- builds a size x size rounded icon image pre-composited on bgc, rotated for the view
local function buildIcon(ctx, path, size, bgc, rot, cell)
    local gpu = ctx.display.gpu
    local img = M.loadPng(gpu, path)
    if not img then return nil end
    local sw, sh = img.getWidth(), img.getHeight()
    if cell then
        -- strip of cell[2] images side by side: crop cell[1] with gpuDraw (never read the whole strip)
        local cw = math.floor(sw / cell[2])
        local crop = gpu.newImage(cw, sh)
        crop.gpuDraw().drawImage(-(cell[1] - 1) * cw, 0, img.ref())
        pcall(img.free)
        img, sw = crop, cw
    end
    local raw = { img.getAsBuffer() }
    pcall(img.free)
    if #raw ~= sw * sh then return nil end
    local br, bg_, bb = toRGBA(bgc)
    local radius = size * 0.22
    local out = {}
    local floor, ceil = math.floor, math.ceil
    for dy = 0, size - 1 do
        local y0 = floor(dy * sh / size)
        local y1 = math.max(y0 + 1, ceil((dy + 1) * sh / size))
        for dx = 0, size - 1 do
            local x0 = floor(dx * sw / size)
            local x1 = math.max(x0 + 1, ceil((dx + 1) * sw / size))
            local sr, sg, sb, sa, n = 0, 0, 0, 0, 0
            for yy = y0, math.min(y1, sh) - 1 do
                for xx = x0, math.min(x1, sw) - 1 do
                    local r, g, b, a = toRGBA(raw[yy * sw + xx + 1])
                    sr, sg, sb, sa, n = sr + r * a, sg + g * a, sb + b * a, sa + a, n + 1
                end
            end
            local R, G, B, A = br, bg_, bb, 0
            if n > 0 and sa > 0 then
                R, G, B, A = sr / sa, sg / sa, sb / sa, sa / n
            end
            -- rounded corner mask (centre sample)
            local px, py = dx + 0.5, dy + 0.5
            local ex = math.max(radius - px, 0, px - (size - radius))
            local ey = math.max(radius - py, 0, py - (size - radius))
            local cov = (ex * ex + ey * ey <= radius * radius) and 1 or 0
            local a = (A / 255) * cov
            local rr = floor(R * a + br * (1 - a))
            local gg = floor(G * a + bg_ * (1 - a))
            local bl = floor(B * a + bb * (1 - a))
            out[dy * size + dx + 1] = 4278190080 + rr * 65536 + gg * 256 + bl
        end
    end
    local final = out
    if rot ~= 0 then
        final = {}
        for v = 0, size - 1 do
            for u = 0, size - 1 do
                local lx, ly
                if rot == 1 then lx, ly = v, size - 1 - u
                elseif rot == 2 then lx, ly = size - 1 - u, size - 1 - v
                else lx, ly = size - 1 - v, u end
                final[v * size + u + 1] = out[ly * size + lx + 1]
            end
        end
    end
    if isSigned(gpu) then
        for i = 1, #final do if final[i] >= 2147483648 then final[i] = final[i] - 4294967296 end end
    end
    local small = gpu.newImage(size, size)
    local c2 = small.gpuDraw()
    local rows = 4
    for y = 0, size - 1, rows do
        local n = math.min(rows, size - y)
        c2.drawBuffer(1, y + 1, size, 1, table.unpack(final, y * size + 1, (y + n) * size))
    end
    return small
end

local PALETTE = { 0xFF2D6BFF, 0xFF8A3FFC, 0xFFD4388F, 0xFF1F9D6B, 0xFFE0802B, 0xFF2AA5C8, 0xFF7A8699 }

function M.new(ctx)
    local display, font = ctx.display, ctx.font
    local g = { ox = 0, oy = 0, w = display.w(), h = display.h(), level = 1, bg = 0xFF000000 }
    local c = ctx.theme.colors()
    g.c = c

    function g.setView(ox, oy, w, h) g.ox, g.oy, g.w, g.h = ox, oy, w, h end

    function g.rect(x, y, w, h, color)
        x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
        if x < 1 then w = w + x - 1; x = 1 end
        if y < 1 then h = h + y - 1; y = 1 end
        w = math.min(w, g.w + 1 - x)
        h = math.min(h, g.h + 1 - y)
        if w < 1 or h < 1 then return end
        display.rect(x + g.ox - 1, y + g.oy - 1, w, h, color)
    end

    function g.clear(color)
        g.bg = color or g.c.bg
        g.rect(1, 1, g.w, g.h, g.bg)
    end

    function g.roundRect(x, y, w, h, r, color)
        x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
        if w < 1 or h < 1 then return end
        r = math.min(math.floor(r or 0), math.floor(math.min(w, h) / 2))
        if r <= 0 then g.rect(x, y, w, h, color) return end
        local t = insetsFor(r)
        local i = 0
        while i < r do
            local ins, j = t[i], i
            while j + 1 < r and t[j + 1] == ins do j = j + 1 end
            local n = j - i + 1
            g.rect(x + ins, y + i, w - 2 * ins, n, color)
            g.rect(x + ins, y + h - 1 - j, w - 2 * ins, n, color)
            i = j + 1
        end
        g.rect(x, y + r, w, h - 2 * r, color)
    end

    function g.line(x1, y1, x2, y2, t, color)
        local dx, dy = x2 - x1, y2 - y1
        local n = math.max(math.abs(dx), math.abs(dy))
        t = t or 2
        for i = 0, n do
            local f = n == 0 and 0 or i / n
            g.rect(math.floor(x1 + dx * f), math.floor(y1 + dy * f), t, t, color)
        end
    end

    -- filled triangle pointing up or down, apex at (cx, y)
    function g.tri(cx, y, size, up, color)
        for i = 0, size - 1 do
            local row = up and i or (size - 1 - i)
            g.rect(cx - i, y + row, 2 * i + 1, 1, color)
        end
    end

    local function resolve(role)
        if type(role) == "number" then return font.level(role) end
        return font.role(role or "body", g.level)
    end

    function g.textWidth(str, role)
        if not font then return #tostring(str) * 6 end
        local size, scale = resolve(role)
        return font.width(str, size, scale)
    end

    function g.lineHeight(role)
        if not font then return 12 end
        local size, scale = resolve(role)
        return font.height(size, scale)
    end

    function g.fit(str, maxw, role)
        if not font then return tostring(str) end
        local size, scale = resolve(role)
        return font.fit(str, maxw, size, scale)
    end

    -- word wrap to lines no wider than maxw
    function g.wrap(str, maxw, role)
        str = tostring(str)
        local lines = {}
        local cw = g.textWidth("M", role)
        local per = math.max(1, math.floor(maxw / math.max(1, cw)))
        for para in (str .. "\n"):gmatch("(.-)\n") do
            if para == "" then
                lines[#lines + 1] = ""
            else
                local cur = ""
                for word in para:gmatch("%S+") do
                    while #word > per do
                        if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
                        lines[#lines + 1] = word:sub(1, per)
                        word = word:sub(per + 1)
                    end
                    if cur == "" then cur = word
                    elseif #cur + 1 + #word <= per then cur = cur .. " " .. word
                    else lines[#lines + 1] = cur; cur = word end
                end
                if cur ~= "" then lines[#lines + 1] = cur end
            end
        end
        return lines
    end

    function g.text(x, y, str, role, color, bg)
        if not font then return 0 end
        str = tostring(str)
        if #str == 0 then return 0 end
        local size, scale = resolve(role)
        x, y = math.floor(x), math.floor(y)
        local h = font.height(size, scale)
        local w = font.width(str, size, scale)
        if y < 1 or y + h - 1 > g.h or x > g.w or x + w - 1 < 1 then return w end
        if x < 1 then return w end
        if x + w - 1 > g.w then str = font.fit(str, g.w - x + 1, size, scale) end
        font.draw(x + g.ox - 1, y + g.oy - 1, str, color or g.c.text, bg or g.bg, size, scale)
        return w
    end

    function g.textCentered(cx, y, str, role, color, bg)
        local w = g.textWidth(str, role)
        return g.text(cx - math.floor(w / 2), y, str, role, color, bg)
    end

    -- draw an image (already physical, pre-rotated) at a logical rectangle
    function g.image(img, x, y, w, h)
        local px, py = font.rectToPhys(x + g.ox - 1, y + g.oy - 1, w, h)
        pcall(display.gpu.drawImage, px, py, img.ref())
    end

    -- app icon: AppIcon.png scaled and rounded, or a letter tile
    function g.icon(app, x, y, size, bg)
        bg = bg or g.bg
        local img
        if app.icon then
            local key = app.icon .. ":" .. size .. ":" .. bg .. ":" .. display.rot .. ":" .. (app.cell and (app.cell[1] .. "/" .. app.cell[2]) or "")
            local e = iconCache[key]
            if e == nil then
                local ok, res = pcall(buildIcon, ctx, app.icon, size, bg, display.rot, app.cell)
                e = (ok and res) or false
                if not e then ctx.log("icon failed: " .. app.icon .. " " .. tostring(ok and "no image" or res)) end
                iconCache[key] = e
            end
            if e then img = e end
        end
        if img then
            g.image(img, x, y, size, size)
        else
            local name = tostring(app.name or app.id or "?")
            local sum = 0
            for i = 1, #name do sum = sum + name:byte(i) end
            local col = PALETTE[sum % #PALETTE + 1]
            g.roundRect(x, y, size, size, math.floor(size * 0.22), col)
            local letter = name:sub(1, 1):upper()
            local lvl = size >= 48 and 4 or 2
            local lw, lh = g.textWidth(letter, lvl), g.lineHeight(lvl)
            g.text(x + math.floor((size - lw) / 2), y + math.floor((size - lh) / 2), letter, lvl, 0xFFFFFFFF, col)
        end
    end

    return g
end

function M.clearIcons() iconCache = {} end

return M
