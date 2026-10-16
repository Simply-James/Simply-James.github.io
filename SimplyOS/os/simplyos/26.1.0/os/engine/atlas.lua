-- /os/engine/atlas.lua
-- Atlas loader. Descriptor: return {image="cards.png", grid={cellW,cellH,cols,rows}, names={...}, sprites={...}}
-- VRAM is 16 MB shared: at most two atlases resident, a load that does not fit is refused.
local gfxmod = dofile("/os/engine/gfx.lua")
local A = {}
local resident = {}

function A.load(ctx, descPath)
    local gpu = ctx.display.gpu
    local fn = loadfile(descPath, "t", {})
    local desc = fn and fn()
    if type(desc) ~= "table" or not desc.image then return nil, "bad atlas descriptor" end
    if #resident >= 2 then return nil, "too many atlases loaded" end
    local dir = fs.getDir(descPath)
    local img = gfxmod.loadPng(gpu, fs.combine(dir, desc.image))
    if not img then return nil, "image missing" end
    local iw, ih = img.getWidth(), img.getHeight()
    local need = iw * ih * 4
    local okm, free = pcall(function() return gpu.getMaxMemory() - gpu.getUsedMemory() end)
    if okm and free < need + 1000000 then
        pcall(img.free)
        return nil, "not enough video memory"
    end
    local at = { desc = desc, img = img, iw = iw, ih = ih, index = {} }
    for i, n in ipairs(desc.names or {}) do at.index[n] = i end
    resident[#resident + 1] = at
    return at
end

function A.unload(at)
    for i, a in ipairs(resident) do if a == at then table.remove(resident, i) break end end
    if at.img then pcall(at.img.free); at.img = nil end
    at.tex = nil
end

-- u0, u1, vTop, vBottom of a named grid cell
function A.uv(at, name)
    local gr = at.desc.grid
    local i = at.index[name]
    if not i then return nil end
    local col = (i - 1) % gr.cols + 1
    local row = math.floor((i - 1) / gr.cols) + 1
    local cw, ch = gr.cellW, gr.cellH
    return (col - 1) * cw / at.iw, col * cw / at.iw, (row - 1) * ch / at.ih, row * ch / at.ih
end

return A
