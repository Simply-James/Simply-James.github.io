-- /os/engine/ui.lua
-- UI kit: button, list (rows), keyboard, textEntry, confirm, page. Built from E (see init.lua).
return function(E)
local ui = {}

local function card(g, x, y, w, h, color)
    g.roundRect(x, y, w, h, math.min(E.m.radius, math.floor(h / 2)), color)
end
ui.card = card

local function inside(o, px, py)
    return px >= o.x and px < o.x + o.w and py >= o.y and py < o.y + o.h
end

local DANGER = 0xFFC93C3C

-- ============================================================ button
function ui.button(o)
    local b = { x = o.x or 1, y = o.y or 1, w = o.w or 100, h = o.h or E.m.target, label = o.label or "",
        onTap = o.onTap, style = o.style or "plain", enabled = o.enabled ~= false, holdSecs = o.holdSecs,
        progress = 0, fired = false, visible = true }
    function b:setRect(x, y, w, h) self.x, self.y, self.w, self.h = x, y, w or self.w, h or self.h end
    function b:draw(g)
        local c = E.c
        local col = self.style == "primary" and c.accent or self.style == "danger" and DANGER or c.card
        local tcol = (self.style == "plain") and c.text or 0xFFFFFFFF
        if not self.enabled then col, tcol = c.raised, c.muted end
        card(g, self.x, self.y, self.w, self.h, col)
        if self.progress > 0 then
            local pw = math.floor(self.w * math.min(1, self.progress))
            g.roundRect(self.x, self.y + self.h - 4, math.max(2, pw), 4, 2, 0xFFFFFFFF)
        end
        local txt = g.fit(self.label, self.w - 8, "body")
        local ty = self.y + math.floor((self.h - g.lineHeight("body")) / 2)
        g.textCentered(self.x + math.floor(self.w / 2), ty, txt, "body", tcol, col)
    end
    function b:touch(px, py)
        if not inside(self, px, py) then return false end
        if not self.enabled then return true end
        if self.holdSecs then self.progress, self.fired = 0.01, false
        elseif self.onTap then self.onTap() end
        E.dirty()
        return true
    end
    function b:hold(px, py, secs)
        if self.holdSecs and not self.fired then
            self.progress = secs / self.holdSecs
            if secs >= self.holdSecs then
                self.fired = true
                if self.onTap then self.onTap() end
            end
            E.dirty()
        end
    end
    function b:release() if self.progress > 0 then self.progress = 0; E.dirty() end end
    return b
end

-- ============================================================ list
function ui.list(o)
    local L = { x = o.x or 1, y = o.y or 1, w = o.w or 100, h = o.h or 100, rows = o.rows or {}, top = 1,
        hits = {}, dragAcc = 0, visible = true }

    function L:setRect(x, y, w, h) self.x, self.y, self.w, self.h = x, y, w, h end
    function L:setRows(rows, keep)
        self.rows = rows
        if not keep then self.top = 1 end
    end

    local function spacing() return math.max(2, math.floor(E.m.pad / 3)) end

    local function rowHeight(g, r, innerW)
        local m = E.m
        local lh = g.lineHeight("body")
        local vpad = math.floor(m.pad * 0.75)
        local base = math.max(m.row, lh + 2 * vpad)
        local k = r.kind
        if r.h then return r.h end
        if k == "gap" then return m.pad end
        if k == "header" then return g.lineHeight(r.role or "caption") + math.floor(m.pad * 0.8) end
        if k == "text" or k == "bubble" then
            local w = innerW - 2 * m.pad
            if k == "bubble" then w = math.floor(innerW * 0.78) - 2 * m.pad end
            local n = #g.wrap(r.text or "", w, r.role or "body")
            local extra = (k == "bubble" and r.status) and (g.lineHeight("caption") + 2) or 0
            return n * g.lineHeight(r.role or "body") + 2 * vpad + extra
        end
        if k == "item" then return 2 * lh + 2 * vpad end
        if k == "bar" then return base + g.lineHeight("caption") + 2 end
        return base
    end

    local function layout(self, g)
        local sp = spacing()
        local n = #self.rows
        local function measure(innerW)
            local hs, total = {}, 0
            for i, r in ipairs(self.rows) do
                hs[i] = rowHeight(g, r, innerW)
                total = total + hs[i] + (i > 1 and sp or 0)
            end
            return hs, total
        end
        local sbw = 0
        local hs, total = measure(self.w)
        if total > self.h then
            sbw = E.m.target
            hs, total = measure(self.w - sbw)
        end
        self.hs, self.sbw, self.sp = hs, sbw, sp
        -- clamp top so the last page is full
        local used, i = 0, n
        while i >= 1 do
            local need = hs[i] + (used > 0 and sp or 0)
            if used + need <= self.h then used = used + need; i = i - 1 else break end
        end
        local lastTop = math.max(1, i + 1)
        if self.top > lastTop then self.top = lastTop end
        if self.top < 1 then self.top = 1 end
        local vis, y = 0, 0
        for j = self.top, n do
            local need = hs[j] + (vis > 0 and sp or 0)
            if y + need <= self.h then y = y + need; vis = vis + 1 else break end
        end
        self.vis = math.max(1, vis)
        self.scrolling = sbw > 0
    end

    local function addHit(self, x, y, w, h, fn, hold, release)
        self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn, hold = hold, release = release }
    end

    local function drawRow(self, g, r, x, y, w, h)
        local c, m = E.c, E.m
        local k = r.kind
        local pad = m.pad
        local lh = g.lineHeight("body")
        local ty = y + math.floor((h - lh) / 2)
        if k == "gap" then return end
        if k == "header" then
            g.text(x + 4, y + math.floor(m.pad * 0.5), r.text or "", r.role or "caption", r.color or c.muted, c.bg)
            return
        end
        if k == "bubble" then
            local bw = math.floor(w * 0.78)
            local bx = (r.dir == "out") and (x + w - bw) or x
            local col = (r.dir == "out") and c.accent or c.card
            card(g, bx, y, bw, h, col)
            local lines = g.wrap(r.text or "", bw - 2 * pad, "body")
            local ly = y + math.floor(m.pad * 0.75)
            for _, ln in ipairs(lines) do
                g.text(bx + pad, ly, ln, "body", (r.dir == "out") and 0xFFFFFFFF or c.text, col)
                ly = ly + g.lineHeight("body")
            end
            if r.status then
                g.text(bx + pad, ly + 1, r.status, "caption", (r.dir == "out") and 0xFFDDE3FF or c.muted, col)
            end
            if r.onTap then addHit(self, bx, y, bw, h, r.onTap) end
            return
        end
        if k == "swatches" then
            card(g, x, y, w, h, c.card)
            g.text(x + pad, ty, g.fit(r.label or "", math.floor(w / 2) - pad, "body"), "body", c.text, c.card)
            local sz = math.min(h - 2 * math.floor(pad * 0.6), E.m.target - 8)
            local sx = x + w - pad - (#r.options * (sz + 8)) + 8
            for i, opt in ipairs(r.options) do
                local px = sx + (i - 1) * (sz + 8)
                local py = y + math.floor((h - sz) / 2)
                if r.selected == opt.name then g.roundRect(px - 3, py - 3, sz + 6, sz + 6, math.floor(sz / 3) + 2, c.text) end
                g.roundRect(px, py, sz, sz, math.floor(sz / 3), opt.color)
                addHit(self, px - 4, y, sz + 8, h, function() if r.onPick then r.onPick(opt.name) end end)
            end
            return
        end
        if k == "custom" then
            if r.draw then r.draw(g, x, y, w, h, self) end
            if r.onTap then addHit(self, x, y, w, h, r.onTap) end
            return
        end

        card(g, x, y, w, h, (k == "button" and r.style == "primary") and c.accent
            or (k == "button" and r.style == "danger") and DANGER or c.card)
        local cardCol = (k == "button" and r.style == "primary") and c.accent
            or (k == "button" and r.style == "danger") and DANGER or c.card

        if k == "text" then
            local ly = y + math.floor(m.pad * 0.75)
            for _, ln in ipairs(g.wrap(r.text or "", w - 2 * pad, r.role or "body")) do
                g.text(x + pad, ly, ln, r.role or "body", r.color or c.text, c.card)
                ly = ly + g.lineHeight(r.role or "body")
            end
            if r.onTap then addHit(self, x, y, w, h, r.onTap) end
        elseif k == "nav" or k == "info" then
            local val = tostring(r.value or "")
            local vw = g.textWidth(val, "body")
            local chev = (k == "nav") and (g.textWidth(">", "body") + 8) or 0
            local maxLabel = w - 2 * pad - chev - math.min(vw, math.floor(w * 0.5)) - 8
            g.text(x + pad, ty, g.fit(r.label or "", maxLabel, "body"), "body", c.text, c.card)
            if val ~= "" then
                local fv = g.fit(val, math.floor(w * 0.5), "body")
                g.text(x + w - pad - chev - g.textWidth(fv, "body"), ty, fv, "body", c.muted, c.card)
            end
            if k == "nav" then g.text(x + w - pad - g.textWidth(">", "body"), ty, ">", "body", c.muted, c.card) end
            if r.onTap then addHit(self, x, y, w, h, r.onTap) end
        elseif k == "toggle" then
            g.text(x + pad, ty, g.fit(r.label or "", w - 3 * pad - 60, "body"), "body", c.text, c.card)
            local ph = math.floor(h * 0.5)
            local pw = ph * 2
            local px, py = x + w - pad - pw, y + math.floor((h - ph) / 2)
            g.roundRect(px, py, pw, ph, math.floor(ph / 2), r.on and c.accent or c.raised)
            local kn = ph - 4
            g.roundRect(r.on and (px + pw - kn - 2) or (px + 2), py + 2, kn, kn, math.floor(kn / 2), 0xFFFFFFFF)
            addHit(self, x, y, w, h, function()
                r.on = not r.on
                if r.onChange then r.onChange(r.on) end
            end)
        elseif k == "stepper" then
            g.text(x + pad, ty, g.fit(r.label or "", math.floor(w / 2) - pad, "body"), "body", c.text, c.card)
            local bs = math.min(h - 8, E.m.target)
            local by = y + math.floor((h - bs) / 2)
            local plusX = x + w - pad - bs
            local val = tostring(r.value or "")
            local valW = math.max(g.textWidth(val, "body"), g.textWidth("000", "body"))
            local minusX = plusX - 8 - valW - 8 - bs
            g.roundRect(minusX, by, bs, bs, math.floor(bs / 3), c.raised)
            g.rect(minusX + math.floor(bs / 4), by + math.floor(bs / 2) - 1, math.floor(bs / 2), 3, c.text)
            g.roundRect(plusX, by, bs, bs, math.floor(bs / 3), c.raised)
            g.rect(plusX + math.floor(bs / 4), by + math.floor(bs / 2) - 1, math.floor(bs / 2), 3, c.text)
            g.rect(plusX + math.floor(bs / 2) - 1, by + math.floor(bs / 4), 3, math.floor(bs / 2), c.text)
            g.textCentered(minusX + bs + 8 + math.floor(valW / 2), ty, val, "body", c.text, c.card)
            addHit(self, minusX - 4, y, bs + 8, h, function() if r.onMinus then r.onMinus() end end)
            addHit(self, plusX - 4, y, bs + 8, h, function() if r.onPlus then r.onPlus() end end)
        elseif k == "button" then
            local tcol = (r.style == "primary" or r.style == "danger") and 0xFFFFFFFF or c.text
            g.textCentered(x + math.floor(w / 2), ty, g.fit(r.label or "", w - 2 * pad, "body"), "body", tcol, cardCol)
            if r.holdSecs then
                local p = r.progress or 0
                if p > 0 then g.roundRect(x, y + h - 4, math.max(2, math.floor(w * math.min(1, p))), 4, 2, 0xFFFFFFFF) end
                addHit(self, x, y, w, h, function() r.progress, r.fired = 0.01, false end,
                    function(secs)
                        r.progress = secs / r.holdSecs
                        if secs >= r.holdSecs and not r.fired then r.fired = true; if r.onTap then r.onTap() end end
                    end,
                    function() r.progress = 0 end)
            elseif r.onTap then
                addHit(self, x, y, w, h, r.onTap)
            end
        elseif k == "item" then
            local rw = r.right and (g.textWidth(r.right, "body") + pad) or 0
            local ly = y + math.floor(m.pad * 0.75)
            g.text(x + pad, ly, g.fit(r.title or "", w - 2 * pad - rw, "body"), "body", c.text, c.card)
            g.text(x + pad, ly + lh, g.fit(r.text or "", w - 2 * pad - rw, "body"), "body", c.muted, c.card)
            if r.right then
                g.text(x + w - pad - g.textWidth(r.right, "body"), y + math.floor((h - lh) / 2), r.right, "body", c.muted, c.card)
                addHit(self, x + w - 2 * pad - g.textWidth(r.right, "body"), y, 2 * pad + g.textWidth(r.right, "body"), h,
                    function() if r.onRight then r.onRight() end end)
            end
            if r.onTap then addHit(self, x, y, w - rw - pad, h, r.onTap) end
        elseif k == "bar" then
            local ly = y + math.floor(m.pad * 0.5)
            g.text(x + pad, ly, g.fit(r.label or "", math.floor(w / 2), "body"), "body", c.text, c.card)
            local val = tostring(r.value or "")
            g.text(x + w - pad - g.textWidth(val, "body"), ly, val, "body", c.muted, c.card)
            local by = ly + lh + 4
            local bw = w - 2 * pad
            g.roundRect(x + pad, by, bw, 8, 4, c.raised)
            local fw = math.floor(bw * math.max(0, math.min(1, r.frac or 0)))
            if fw > 0 then g.roundRect(x + pad, by, math.max(8, fw), 8, 4, c.accent) end
        end
    end

    function L:draw(g)
        self.hits = {}
        layout(self, g)
        local pad = 0
        local x, w = self.x, self.w - self.sbw
        local y = self.y
        local n = #self.rows
        local last = math.min(n, self.top + self.vis - 1)
        for i = self.top, last do
            drawRow(self, g, self.rows[i], x, y, w, self.hs[i])
            y = y + self.hs[i] + self.sp
        end
        if self.scrolling then
            local bs = self.sbw - 6
            local bx = self.x + self.w - bs
            local c = E.c
            local canUp, canDown = self.top > 1, last < n
            card(g, bx, self.y, bs, bs, c.card)
            g.tri(bx + math.floor(bs / 2), self.y + math.floor(bs / 2) - 4, 8, true, canUp and c.text or c.raised)
            local dy = self.y + self.h - bs
            card(g, bx, dy, bs, bs, c.card)
            g.tri(bx + math.floor(bs / 2), dy + math.floor(bs / 2) - 4, 8, false, canDown and c.text or c.raised)
            local page = math.max(1, self.vis - 1)
            addHit(self, bx, self.y, bs, bs, function() self.top = math.max(1, self.top - page) end)
            addHit(self, bx, dy, bs, bs, function() self.top = self.top + page end)
        end
    end

    function L:touch(px, py)
        if not inside(self, px, py) then return false end
        self.dragAcc = 0
        for i = #self.hits, 1, -1 do
            local h = self.hits[i]
            if inside(h, px, py) then
                self.active = h
                h.fn(px, py)
                E.dirty()
                return true
            end
        end
        self.active = nil
        return true
    end

    function L:drag(px, py, dx, dy)
        self.dragAcc = self.dragAcc + dy
        local step = E.m.row
        while self.dragAcc <= -step do self.top = self.top + 1; self.dragAcc = self.dragAcc + step end
        while self.dragAcc >= step do self.top = math.max(1, self.top - 1); self.dragAcc = self.dragAcc - step end
        E.dirty()
    end

    function L:hold(px, py, secs)
        if self.active and self.active.hold then self.active.hold(secs); E.dirty() end
    end

    function L:release()
        if self.active and self.active.release then self.active.release() end
        self.active = nil
        E.dirty()
    end

    return L
end

-- ============================================================ keyboard
local function charRow(s) local t = {} for ch in s:gmatch(".") do t[#t + 1] = { ch, 1, "char", ch } end return t end

function ui.keyboard(o)
    local K = { x = 1, y = 1, w = 100, h = 100, page = "abc", shift = false, hits = {}, visible = true }
    function K:setRect(x, y, w, h) self.x, self.y, self.w, self.h = x, y, w, h end

    local function rows(self)
        local r = {}
        if self.page == "abc" then
            r[1] = charRow("qwertyuiop")
            r[2] = { { "", 0.5, "gap" } }
            for _, k in ipairs(charRow("asdfghjkl")) do r[2][#r[2] + 1] = k end
            r[2][#r[2] + 1] = { "", 0.5, "gap" }
            r[3] = { { "Shift", 1.5, "shift" } }
            for _, k in ipairs(charRow("zxcvbnm")) do r[3][#r[3] + 1] = k end
            r[3][#r[3] + 1] = { "<-", 1.5, "back" }
        else
            r[1] = charRow("1234567890")
            r[2] = charRow("-/:;()$&@\"")
            r[3] = { { "", 1.5, "gap" } }
            for _, k in ipairs(charRow(".,?!'_#")) do r[3][#r[3] + 1] = k end
            r[3][#r[3] + 1] = { "<-", 1.5, "back" }
        end
        local r4 = { { self.page == "abc" and "123" or "abc", 1.5, "page" } }
        if o.onEnter then
            r4[#r4 + 1] = { "space", 4, "char", " " }
            r4[#r4 + 1] = { "ret", 1.5, "enter" }
        else
            r4[#r4 + 1] = { "space", 5.5, "char", " " }
        end
        r4[#r4 + 1] = { "OK", 2, "done" }
        r[4] = r4
        return r
    end

    function K:draw(g)
        local c = E.c
        self.hits = {}
        local rs = rows(self)
        local kh = math.floor(self.h / 4)
        for ri, row in ipairs(rs) do
            local total = 0
            for _, k in ipairs(row) do total = total + k[2] end
            local unit = self.w / total
            local x = self.x
            for _, k in ipairs(row) do
                local kw = k[2] * unit
                if k[3] ~= "gap" then
                    local kx, ky = math.floor(x) + 2, self.y + (ri - 1) * kh + 2
                    local w, h = math.floor(kw) - 4, kh - 4
                    local label = k[1]
                    local col = c.card
                    local tcol = c.text
                    if k[3] == "char" and #label == 1 and self.page == "abc" and self.shift then label = label:upper() end
                    if k[3] == "done" then col, tcol = c.accent, 0xFFFFFFFF end
                    if k[3] == "shift" and self.shift then col = c.raised end
                    if k[3] == "back" or k[3] == "page" or k[3] == "enter" or k[3] == "shift" then col = (col == c.accent) and col or c.raised end
                    g.roundRect(kx, ky, w, h, 6, col)
                    local lw = g.textWidth(label, "body")
                    if lw > w - 2 then label = g.fit(label, w - 2, "body"); lw = g.textWidth(label, "body") end
                    g.text(kx + math.floor((w - lw) / 2), ky + math.floor((h - g.lineHeight("body")) / 2), label, "body", tcol, col)
                    self.hits[#self.hits + 1] = { x = kx, y = ky, w = w, h = h, key = k }
                end
                x = x + kw
            end
        end
    end

    function K:touch(px, py)
        if not inside(self, px, py) then return false end
        for _, h in ipairs(self.hits) do
            if inside(h, px, py) then
                local k = h.key
                local kind = k[3]
                if kind == "char" then
                    local ch = k[4]
                    if self.page == "abc" and self.shift then ch = ch:upper(); self.shift = false end
                    if o.onChar then o.onChar(ch) end
                elseif kind == "shift" then self.shift = not self.shift
                elseif kind == "back" then if o.onBackspace then o.onBackspace() end
                elseif kind == "page" then self.page = (self.page == "abc") and "sym" or "abc"
                elseif kind == "enter" then if o.onEnter then o.onEnter() end
                elseif kind == "done" then if o.onDone then o.onDone() end end
                E.dirty()
                break
            end
        end
        return true
    end
    return K
end

-- ============================================================ page / dialogs
-- ui.page{title=, build=function(page) return rows end}  -> scene with a title and a list
function ui.textRows(text, role)
    local g, m = E.g, E.m
    role = role or "body"
    local avail = E.w - 2 * m.pad - m.target - 2 * m.pad
    local lines = g.wrap(text, avail, role)
    local lh = g.lineHeight(role)
    local per = math.max(2, math.floor((E.h * 0.45) / lh))
    local rows = {}
    for i = 1, #lines, per do
        rows[#rows + 1] = { kind = "text", role = role, text = table.concat(lines, "\n", i, math.min(i + per - 1, #lines)) }
    end
    return rows
end

-- ui.page{title=, build=function(page) return rows end, footer={{label=,style=,onTap=}}, update=, back=, event=}
function ui.page(o)
    local scene = E.scene{}
    local list = ui.list{}
    scene.widgets = { list }
    scene.list = list
    local fbtns = {}
    for _, f in ipairs(o.footer or {}) do
        local b = ui.button{ label = f.label, style = f.style, onTap = f.onTap }
        fbtns[#fbtns + 1] = b
        scene.widgets[#scene.widgets + 1] = b
    end
    function scene.rebuild(keepTop)
        list:setRows(o.build(scene) or {}, keepTop ~= false)
        E.dirty()
    end
    function scene:load() self.rebuild(false) if o.onLoad then o.onLoad(self) end end
    function scene:resume() self.rebuild(true) end
    function scene:drawUI(g)
        local m = E.m
        local title = type(o.title) == "function" and o.title() or o.title or ""
        g.text(m.pad, m.pad, g.fit(title, E.w - 2 * m.pad, "title"), "title", E.c.text, E.c.bg)
        local top = m.pad * 2 + g.lineHeight("title")
        local footH = (#fbtns > 0) and (m.target + m.pad) or 0
        list:setRect(m.pad, top, E.w - 2 * m.pad, E.h - top - m.pad - footH)
        if #fbtns > 0 then
            local gap = math.floor(m.pad / 2)
            local bw = math.floor((E.w - 2 * m.pad - gap * (#fbtns - 1)) / #fbtns)
            for i, b in ipairs(fbtns) do
                b:setRect(m.pad + (i - 1) * (bw + gap), E.h - m.target - m.pad, bw, m.target)
            end
        end
    end
    if o.update then scene.update = function(self, dt) return o.update(self, dt) end end
    if o.back then scene.back = o.back end
    if o.event then scene.event = o.event end
    return scene
end

function ui.textEntry(o)
    local text = o.text or ""
    local max = o.max or 200
    local scene = E.scene{}
    local kb
    kb = ui.keyboard{
        onChar = function(ch)
            if #text < max and (not o.allow or ch:match(o.allow)) then text = text .. ch end
        end,
        onBackspace = function() text = text:sub(1, -2) end,
        onEnter = o.multiline and function() if #text < max then text = text .. "\n" end end or nil,
        onDone = function()
            E.pop()
            if o.onDone then o.onDone(text) end
        end,
    }
    scene.widgets = { kb }
    function scene:drawUI(g)
        local m, c = E.m, E.c
        local kh = math.min(math.floor(E.h * 0.55), 4 * m.target)
        kb:setRect(1, E.h - kh + 1, E.w, kh)
        g.text(m.pad, m.pad, g.fit(o.title or "", E.w - 2 * m.pad, "title"), "title", c.text, c.bg)
        local fy = m.pad * 2 + g.lineHeight("title")
        local fh = E.h - kh - fy - m.pad
        if fh > 8 then
            card(g, m.pad, fy, E.w - 2 * m.pad, fh, c.card)
            local lines = g.wrap(text .. "_", E.w - 4 * m.pad, "body")
            local lh = g.lineHeight("body")
            local fit = math.max(1, math.floor((fh - m.pad) / lh))
            local first = math.max(1, #lines - fit + 1)
            local y = fy + math.floor(m.pad / 2)
            for i = first, #lines do
                g.text(m.pad * 2, y, lines[i], "body", c.text, c.card)
                y = y + lh
            end
            local cnt = #text .. "/" .. max
            g.text(E.w - m.pad - g.textWidth(cnt, "caption") - 4, fy + fh - g.lineHeight("caption") - 2, cnt, "caption", c.muted, c.card)
        end
    end
    function scene:back()
        E.pop()
        if o.onCancel then o.onCancel() end
        return true
    end
    return scene
end

function ui.confirm(o)
    local scene = E.scene{}
    local ok = ui.button{ label = o.okText or "OK", style = o.danger and "danger" or "primary",
        holdSecs = o.holdSecs, onTap = function() E.pop(); if o.onOk then o.onOk() end end }
    local cancel = ui.button{ label = "Cancel", onTap = function() E.pop(); if o.onCancel then o.onCancel() end end }
    scene.widgets = { ok, cancel }
    function scene:drawUI(g)
        local m, c = E.m, E.c
        g.text(m.pad, m.pad, g.fit(o.title or "", E.w - 2 * m.pad, "title"), "title", c.text, c.bg)
        local y = m.pad * 2 + g.lineHeight("title")
        for _, ln in ipairs(g.wrap(o.text or "", E.w - 2 * m.pad, "body")) do
            g.text(m.pad, y, ln, "body", c.muted, c.bg)
            y = y + g.lineHeight("body")
        end
        if o.holdSecs then
            y = y + 6
            g.text(m.pad, y, "Hold the button for " .. o.holdSecs .. " seconds", "caption", c.muted, c.bg)
        end
        local bh = m.target
        local by = E.h - 2 * bh - 2 * m.pad
        ok:setRect(m.pad, by, E.w - 2 * m.pad, bh)
        cancel:setRect(m.pad, by + bh + math.floor(m.pad / 2), E.w - 2 * m.pad, bh)
    end
    function scene:back() E.pop(); if o.onCancel then o.onCancel() end return true end
    return scene
end

-- message with one OK button
function ui.notice(title, text)
    local scene = E.scene{}
    local ok = ui.button{ label = "OK", style = "primary", onTap = function() E.pop() end }
    scene.widgets = { ok }
    function scene:drawUI(g)
        local m, c = E.m, E.c
        g.text(m.pad, m.pad, g.fit(title, E.w - 2 * m.pad, "title"), "title", c.text, c.bg)
        local y = m.pad * 2 + g.lineHeight("title")
        for _, ln in ipairs(g.wrap(text, E.w - 2 * m.pad, "body")) do
            g.text(m.pad, y, ln, "body", c.muted, c.bg)
            y = y + g.lineHeight("body")
        end
        ok:setRect(m.pad, E.h - m.target - m.pad, E.w - 2 * m.pad, m.target)
    end
    function scene:back() E.pop() return true end
    return scene
end

return ui
end
