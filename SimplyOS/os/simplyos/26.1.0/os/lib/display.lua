-- /os/lib/display.lua
-- GPU setup and logical screen size. Nothing else may hard code the screen size.
-- display.init()  display.w() display.h() (logical)  display.pw / display.ph (physical)
-- display.setRotation(rot)  display.rect(x,y,w,h,color) (logical)  display.clear(color)  display.sync()
local M = { gpu = nil, pw = 0, ph = 0, rot = 0, font = nil }

function M.init()
    local gpu = peripheral.find("tm_gpu")
    if not gpu then error("no GPU found", 0) end
    for _, s in ipairs({ 128, 64, 32, 16 }) do
        if pcall(gpu.setSize, s) then break end
    end
    local W, H
    for _ = 1, 10 do
        pcall(gpu.refreshSize)
        local ok, w, h = pcall(gpu.getSize)
        if ok and w and h and w > 0 then W, H = w, h break end
        sleep(0.2)
    end
    if not W then error("GPU size unavailable", 0) end
    M.gpu, M.pw, M.ph = gpu, W, H
    return M
end

function M.w() return (M.rot == 1 or M.rot == 3) and M.ph or M.pw end
function M.h() return (M.rot == 1 or M.rot == 3) and M.pw or M.ph end

function M.setRotation(rot)
    M.rot = rot or 0
    if M.font then M.font.setView(M.rot, M.pw, M.ph) end
end

-- safe filled rectangle in logical coordinates (never throws)
function M.rect(x, y, w, h, color)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    local lw, lh = M.w(), M.h()
    if x < 1 then w = w + x - 1; x = 1 end
    if y < 1 then h = h + y - 1; y = 1 end
    w = math.min(w, lw + 1 - x)
    h = math.min(h, lh + 1 - y)
    if w < 1 or h < 1 then return end
    if M.font then x, y, w, h = M.font.rectToPhys(x, y, w, h) end
    pcall(M.gpu.filledRectangle, x, y, w, h, color)
end

function M.clear(color) M.rect(1, 1, M.w(), M.h(), color) end

function M.sync() pcall(M.gpu.sync) end

return M
