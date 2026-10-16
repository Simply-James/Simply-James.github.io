-- /server/log.lua
-- One line per event: "time LEVEL module text". Rotating files. Never log message bodies or keys.
return function(S)
    local M = {}
    local DIR = "/server/logs"
    local ring = {}      -- recent warn/error lines for the Status screen
    local RING_MAX = 20

    local function path(i)
        if i == 0 then return DIR .. "/server.log" end
        return DIR .. "/server.log." .. i
    end

    local function rotate()
        local last = math.max(1, S.config.get("log.maxFiles")) - 1
        if fs.exists(path(last)) then fs.delete(path(last)) end
        for i = last - 1, 0, -1 do
            if fs.exists(path(i)) then fs.move(path(i), path(i + 1)) end
        end
    end

    local function write(level, mod, text)
        local line = S.util.stamp() .. " " .. level .. " " .. mod .. " " .. tostring(text)
        if level ~= "INFO" then
            ring[#ring + 1] = line
            if #ring > RING_MAX then table.remove(ring, 1) end
        end
        pcall(function()
            if not fs.exists(DIR) then fs.makeDir(DIR) end
            if fs.getFreeSpace("/") < 2000 then return end   -- never fill the disk with logs
            local p = path(0)
            if fs.exists(p) and fs.getSize(p) + #line + 1 > S.config.get("log.maxBytes") then rotate() end
            local f = fs.open(p, "a")
            if f then
                f.writeLine(line)
                f.close()
            end
        end)
    end

    function M.info(mod, text) write("INFO", mod, text) end
    function M.warn(mod, text) write("WARN", mod, text) end
    function M.error(mod, text) write("ERROR", mod, text) end

    -- last n warn/error lines since start
    function M.recent(n)
        local out = {}
        for i = math.max(1, #ring - (n or 5) + 1), #ring do out[#out + 1] = ring[i] end
        return out
    end

    -- last n lines of the current log file
    function M.tail(n)
        local lines = {}
        local f = fs.exists(path(0)) and fs.open(path(0), "r")
        if not f then return lines end
        while true do
            local l = f.readLine()
            if not l then break end
            lines[#lines + 1] = l
            if #lines > n then table.remove(lines, 1) end
        end
        f.close()
        return lines
    end

    return M
end
