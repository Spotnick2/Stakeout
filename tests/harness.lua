------------------------------------------------------------
-- harness.lua - tiny assertion harness.
--
--     local H = dofile("tests/harness.lua")
--     H.eq(actual, expected, "what this proves")
--     H.done("test_thing")
--
-- Run from the repo root so the relative paths resolve.
------------------------------------------------------------

local H = { run = 0, failures = 0 }

function H.check(cond, msg)
    H.run = H.run + 1
    if not cond then
        H.failures = H.failures + 1
        print("  FAIL: " .. (msg or "assertion failed"))
    end
end

function H.eq(a, b, msg)
    H.check(a == b, (msg or "values differ") ..
        "  (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
end

-- A whole file as text with CRLF normalised, or nil if it does not exist.
function H.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return (s:gsub("\r\n", "\n"))
end

-- The TOC as a list of lines, trailing whitespace stripped.
function H.tocLines()
    local toc = assert(H.readFile("Stakeout.toc"), "Stakeout.toc not found - run from the repo root")
    local lines = {}
    for line in (toc .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("%s+$", ""))
    end
    return lines
end

-- The value of a `## Name: value` directive, or nil.
function H.directive(name)
    -- Escape the name: "X-Curse-Project-ID" contains "-", a Lua pattern
    -- quantifier, so an unescaped match silently finds nothing.
    local escaped = name:gsub("(%W)", "%%%1")
    for _, line in ipairs(H.tocLines()) do
        local value = line:match("^##%s*" .. escaped .. ":%s*(.*)$")
        if value then return value end
    end
    return nil
end

-- The Lua files the TOC loads, in order.
function H.tocFiles()
    local files = {}
    for _, line in ipairs(H.tocLines()) do
        local file = line:match("^%s*([^#%s][^%s]*%.lua)$")
        if file then files[#files + 1] = file end
    end
    return files
end

function H.done(name)
    if H.failures > 0 then
        print(string.format("%s: %d/%d FAILED", name, H.failures, H.run))
        os.exit(1)
    end
    print(string.format("%s: %d tests passed", name, H.run))
end

return H
