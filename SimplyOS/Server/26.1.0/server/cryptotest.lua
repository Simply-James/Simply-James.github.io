-- /server/cryptotest.lua
-- Run on the server: lua /server/cryptotest.lua   (or: /server/cryptotest.lua)
-- Prints and saves (/server/logs/cryptotest.txt) what the accelerator really does,
-- then runs the wrapper's own self-check. Send the output back to fix the wrapper if needed.
local out = {}
local function p(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
    local line = table.concat(t, " ")
    print(line)
    out[#out + 1] = line
end

local function show(v)
    if type(v) == "string" then return "string(" .. #v .. ") " .. v:sub(1, 70) end
    if type(v) == "table" then
        local ok, s = pcall(textutils.serialize, v)
        return "table(" .. #v .. ") " .. (ok and s:gsub("%s+", " "):sub(1, 70) or "?")
    end
    return type(v) .. " " .. tostring(v)
end

local hw = peripheral.find("cryptographic_accelerator")
if not hw then
    p("no cryptographic_accelerator attached")
else
    p("methods:", table.concat(peripheral.getMethods(peripheral.getName(hw)), ", "))
    local calls = {
        { "sha256('abc')", hw.sha256, "abc" },
        { "hmacSha256('Jefe', msg)", hw.hmacSha256, "Jefe", "what do ya want for nothing?" },
        { "hmacSha256(msg, 'Jefe')", hw.hmacSha256, "what do ya want for nothing?", "Jefe" },
        { "randomBytes(16)", hw.randomBytes, 16 },
        { "random()", hw.random },
    }
    for _, c in ipairs(calls) do
        local r = table.pack(pcall(c[2], table.unpack(c, 3)))
        if r[1] then p(c[1], "->", show(r[2])) else p(c[1], "ERROR", tostring(r[2])) end
    end
    p("expected sha256('abc')  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    p("expected hmac('Jefe')   5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
end

local fn = assert(loadfile("/server/crypto.lua", "t", _ENV))
local crypto = fn()({})
crypto.init()
p("--- wrapper ---")
p("mode:", crypto.mode)
p("describe:", crypto.describe())
p("pure self-test:", crypto.info.pure)
p("sha256('abc'):", crypto.sha256("abc"))
p("hmac('Jefe',..):", crypto.hmac("Jefe", "what do ya want for nothing?"))
p("random(16):", crypto.random(16))

pcall(function()
    if not fs.exists("/server/logs") then fs.makeDir("/server/logs") end
    local f = fs.open("/server/logs/cryptotest.txt", "w")
    f.write(table.concat(out, "\n") .. "\n")
    f.close()
end)
print("saved /server/logs/cryptotest.txt")
