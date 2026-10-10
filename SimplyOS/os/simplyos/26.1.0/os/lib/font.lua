-- /os/lib/font.lua
-- Own bitmap text renderer. The GPU's built-in drawText draws plain bars on
-- this setup, so text is built as small images from /os/lib/fontdata.lua and
-- drawn with drawImage. Built images are cached.
--
-- local font = dofile("/os/lib/font.lua")
-- font.init(gpu)
-- font.draw(x, y, "text", fgColor, bgColor, "small" | "normal", scale)
-- font.width("text", size, scale)  font.height(size, scale)
-- font.fit("text", maxPixels, size, scale)  -> shortened text that fits
-- bgColor nil = transparent background (needs drawImage to blend alpha)
--
-- Rotation: font.setView(rot, physicalW, physicalH). After that every
-- coordinate given to font.draw is LOGICAL (what the user sees), and the
-- font rotates the text onto the physical screen.
--   rot 0 = portrait
--   rot 1 = phone turned counter-clockwise (top of phone points left)
--   rot 2 = upside down
--   rot 3 = phone turned clockwise (top of phone points right)
-- font.rectToPhys(x, y, w, h) and font.pointToLogical(px, py) expose the
-- same mapping so other drawing code can use it too. Coordinates are 1-based.
local data = dofile("/os/lib/fontdata.lua")

local M = {}

local gpu

local signed = true

local cache = {}

local cacheCount = 0

local MAX_CACHE = 300

local PIXEL_BUDGET = 2048

local stamp = 0

local viewRot, viewPW, viewPH = 0, 0, 0

M.broken = nil

-- ============================================================
-- INIT / VIEW
-- ============================================================

function M.init(g)

    gpu = g

    -- find out whether the GPU hands out signed or unsigned pixel numbers
    pcall(function()

        local im = gpu.newImage(1, 1)

        im.setRGB(1, 1, 0xFFFF0000)

        local v = tonumber((im.getAsBuffer()))

        if v then signed = v < 0 end

        pcall(im.free)
    end)

    return M
end

function M.setView(rot, pw, ph)

    viewRot = rot or 0

    viewPW = pw or viewPW

    viewPH = ph or viewPH
end

function M.getView() return viewRot, viewPW, viewPH end

-- logical rectangle -> physical rectangle (x, y, w, h)
function M.rectToPhys(x, y, w, h)

    if viewRot == 1 then return viewPW + 2 - y - h, x, h, w end

    if viewRot == 2 then return viewPW + 2 - x - w, viewPH + 2 - y - h, w, h end

    if viewRot == 3 then return y, viewPH + 2 - x - w, h, w end

    return x, y, w, h
end

-- physical point (touch) -> logical point
function M.pointToLogical(px, py)

    if viewRot == 1 then return py, viewPW + 1 - px end

    if viewRot == 2 then return viewPW + 1 - px, viewPH + 1 - py end

    if viewRot == 3 then return viewPH + 1 - py, px end

    return px, py
end

local function pixel(c)

    c = c % 4294967296

    if c < 16777216 then c = c + 4278190080 end

    if signed and c >= 2147483648 then c = c - 4294967296 end

    return c
end

-- ============================================================
-- METRICS (always logical, never rotated)
-- ============================================================

-- text levels (OS_DEVDOC 9.3): 1 small x1, 2 normal x1, 3 small x2, 4 normal x2
local LEVELS = { {"small", 1}, {"normal", 1}, {"small", 2}, {"normal", 2} }

local function clampLevel(n)
    return math.max(1, math.min(4, math.floor(tonumber(n) or 1)))
end

-- font.level(n) -> size, scale
function M.level(n)
    local l = LEVELS[clampLevel(n)]
    return l[1], l[2]
end

-- font.role("body" | "caption" | "title", baseLevel) -> size, scale
function M.role(role, base)
    local n = clampLevel(base)
    if role == "caption" then n = math.max(1, n - 1)
    elseif role == "title" then n = math.min(4, n + 1) end
    return M.level(n)
end

local function info(size)

    return data[size or "small"] or data.small
end

function M.width(str, size, scale)

    return #tostring(str) * info(size).w * (scale or 1)
end

function M.height(size, scale)

    return info(size).h * (scale or 1)
end

function M.fit(str, maxPixels, size, scale)

    str = tostring(str)

    local cw = info(size).w * (scale or 1)

    local n = math.floor(maxPixels / cw)

    if n < 1 then return "" end

    if #str <= n then return str end

    if n <= 2 then return str:sub(1, n) end

    return str:sub(1, n - 2) .. ".."
end

-- ============================================================
-- IMAGE CACHE
-- ============================================================

local function evict()

    local list = {}

    for key, entry in pairs(cache) do list[#list + 1] = {key = key, stamp = entry.stamp} end

    table.sort(list, function(a, b) return a.stamp < b.stamp end)

    for i = 1, math.floor(#list / 2) do

        local entry = cache[list[i].key]

        if entry and entry.img then pcall(entry.img.free) end

        cache[list[i].key] = nil

        cacheCount = cacheCount - 1
    end
end

local function makeImage(width, height, px, n)

    local ok, img = pcall(function()
        return gpu.imageFromBuffer(width, table.unpack(px, 1, n))
    end)

    if ok and img then return img end

    -- slow fallback: set pixels one by one
    local ok2, img2 = pcall(function()

        local im = gpu.newImage(width, height)

        for y = 1, height do

            for x = 1, width do im.setRGB(x, y, px[(y - 1) * width + x]) end
        end

        return im
    end)

    if ok2 and img2 then return img2 end

    M.broken = tostring(img)

    return nil
end

-- upright text (rot 0)
local function build(chunk, fg, bg, size, scale)

    local f = info(size)

    local on = pixel(fg)

    local off = bg and pixel(bg) or 0

    local glyphs = {}

    for i = 1, #chunk do

        glyphs[i] = f.glyphs[chunk:byte(i)] or f.glyphs[63]
    end

    local px = {}

    local n = 0

    for row = 0, f.h - 1 do

        local base = row * f.w

        local line = {}

        local ln = 0

        for i = 1, #chunk do

            local g = glyphs[i]

            for col = 1, f.w do

                local v = (g:byte(base + col) == 49) and on or off

                for _ = 1, scale do

                    ln = ln + 1

                    line[ln] = v
                end
            end
        end

        for _ = 1, scale do

            for i = 1, ln do px[n + i] = line[i] end

            n = n + ln
        end
    end

    return makeImage(#chunk * f.w * scale, f.h * scale, px, n)
end

-- rotated text (rot 1, 2, 3): the image is built in physical pixel order
local function buildRot(chunk, fg, bg, size, scale, rot)

    local f = info(size)

    local on = pixel(fg)

    local off = bg and pixel(bg) or 0

    local glyphs = {}

    for i = 1, #chunk do

        glyphs[i] = f.glyphs[chunk:byte(i)] or f.glyphs[63]
    end

    local cwp = f.w * scale

    local LWc = #chunk * cwp

    local LHc = f.h * scale

    local pw, ph

    if rot == 1 or rot == 3 then
        pw, ph = LHc, LWc
    else
        pw, ph = LWc, LHc
    end

    local floor = math.floor

    local px = {}

    local n = 0

    for v = 0, ph - 1 do

        for u = 0, pw - 1 do

            local lx, ly

            if rot == 1 then
                lx, ly = v, LHc - 1 - u
            elseif rot == 2 then
                lx, ly = LWc - 1 - u, LHc - 1 - v
            else
                lx, ly = LWc - 1 - v, u
            end

            local g = glyphs[floor(lx / cwp) + 1]

            local col = floor((lx % cwp) / scale) + 1

            local row = floor(ly / scale)

            n = n + 1

            px[n] = (g:byte(row * f.w + col) == 49) and on or off
        end
    end

    return makeImage(pw, ph, px, n)
end

local function getImage(chunk, fg, bg, size, scale, rot)

    local key = (size or "small") .. scale .. "r" .. rot .. ":" .. fg .. ":" ..
                    tostring(bg) .. ":" .. chunk

    local entry = cache[key]

    stamp = stamp + 1

    if entry then

        entry.stamp = stamp

        return entry.img
    end

    if cacheCount >= MAX_CACHE then evict() end

    local img

    if rot == 0 then
        img = build(chunk, fg, bg, size, scale)
    else
        img = buildRot(chunk, fg, bg, size, scale, rot)
    end

    if not img then return nil end

    cache[key] = {img = img, stamp = stamp}

    cacheCount = cacheCount + 1

    return img
end

-- ============================================================
-- DRAW
-- ============================================================

-- x, y are LOGICAL coordinates of the top-left of the text
function M.draw(x, y, str, fg, bg, size, scale)

    if not gpu then error("font.init(gpu) was not called", 2) end

    str = tostring(str)

    if #str == 0 then return end

    scale = math.max(1, math.floor(scale or 1))

    x = math.floor(x)

    y = math.floor(y)

    fg = fg or 0xFFFFFFFF

    local f = info(size)

    local cw = f.w * scale

    local ch = f.h * scale

    local per = math.max(1, math.floor(PIXEL_BUDGET / (cw * ch)))

    local i = 1

    while i <= #str do

        local chunk = str:sub(i, i + per - 1)

        local img = getImage(chunk, fg, bg, size, scale, viewRot)

        if img then

            local px, py = M.rectToPhys(x + (i - 1) * cw, y, #chunk * cw, ch)

            pcall(gpu.drawImage, px, py, img.ref())
        end

        i = i + per
    end
end

function M.clearCache()

    for _, entry in pairs(cache) do

        if entry.img then pcall(entry.img.free) end
    end

    cache = {}

    cacheCount = 0
end

return M
