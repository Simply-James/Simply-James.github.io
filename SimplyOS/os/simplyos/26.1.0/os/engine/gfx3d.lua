-- /os/engine/gfx3d.lua
-- 3D textured cards. One full-screen 3D window for the whole session (kept in a global, cannot be freed).
-- Call order and UV mapping follow GE_DEVDOC 4.6 (vertex first, +y is down, V not flipped).
local atlasmod = dofile("/os/engine/atlas.lua")
local G = {}

function G.new(ctx)
    local g3 = { cards = {}, fov = 90 }
    local gpu = ctx.display.gpu

    local function window()
        if not _G.SimplyGL then
            _G.SimplyGL = gpu.createWindow3D(1, 1, ctx.display.pw, ctx.display.ph)
            _G.SimplyGL.glFrustum(g3.fov, 0.1, 1000)
            _G.SimplyGL.glDirLight(0, 0, -1)
        end
        return _G.SimplyGL
    end

    function g3.camera(opts)
        g3.fov = (opts and opts.fov) or 90
        window().glFrustum(g3.fov, 0.1, 1000)
    end

    -- card{w=0.667, h=1, front={atlas=, name=}, back={atlas=, name=}, x,y,z, rx,ry,rz}
    function g3.card(c) g3.cards[#g3.cards + 1] = c end

    local function texture(gl, at)
        if not at.tex then
            at.tex = gl.glGenTextures()
            gl.glBindTexture(at.tex)
            gl.glTexImage(at.img.ref())
        end
        return at.tex
    end

    local function quad(gl, hx, hy, u0, u1, vt, vb)
        local function vtx(x, y, z, u, v) gl.glVertex(x, y, z); gl.glTexCoord(u, v) end
        gl.glBegin()
        vtx(-hx, -hy, 0, u0, vt) vtx(-hx, hy, 0, u0, vb) vtx(hx, hy, 0, u1, vb)
        vtx(-hx, -hy, 0, u0, vt) vtx(hx, hy, 0, u1, vb) vtx(hx, -hy, 0, u1, vt)
        gl.glEnd()
    end

    -- draws all queued cards, then renders. Returns after gl.sync()
    function g3.flush()
        local gl = window()
        gl.clear()
        gl.glEnable(3553)
        for _, c in ipairs(g3.cards) do
            local hx, hy = (c.w or 0.667) / 2, (c.h or 1) / 2
            gl.glPushMatrix()
            gl.glTranslate(c.x or 0, c.y or 0, c.z or 2.2)
            gl.glRotate(c.ry or 0, 0, 1, 0)
            gl.glColor(255, 255, 255)
            local f = c.front
            if f then
                gl.glBindTexture(texture(gl, f.atlas))
                local u0, u1, vt, vb = atlasmod.uv(f.atlas, f.name)
                if u0 then quad(gl, hx, hy, u0, u1, vt, vb) end
            end
            local b = c.back
            if b then
                gl.glPushMatrix()
                gl.glTranslate(0, 0, 0.002)
                gl.glRotate(180, 0, 1, 0)
                gl.glBindTexture(texture(gl, b.atlas))
                local u0, u1, vt, vb = atlasmod.uv(b.atlas, b.name)
                if u0 then quad(gl, hx, hy, u0, u1, vt, vb) end
                gl.glPopMatrix()
            end
            gl.glPopMatrix()
        end
        gl.render()
        gl.sync()
        g3.cards = {}
    end

    return g3
end

return G
