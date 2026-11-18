------------------------------------------------------------
-- harness.lua - file and TOC helpers for the tests. The assertions are
-- WowTestKit's globals (check, eq, done), loaded by tests/wow_stubs.lua.
--
--     dofile("tests/wow_stubs.lua")
--     local H = dofile("tests/harness.lua")
--     eq(actual, expected, "what this proves")
--     done("test_thing")
--
-- Run from the repo root so the relative paths resolve.
------------------------------------------------------------

local H = {}

local TOC = "Stakeout.toc"

-- A whole file as text with CRLF normalised, or nil if it does not exist.
function H.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return (s:gsub("\r\n", "\n"))
end

-- The value of a `## Name: value` directive, or nil.
function H.directive(name)
    local toc = assert(H.readFile(TOC), TOC .. " not found - run from the repo root")
    -- Escape the name: "X-Curse-Project-ID" contains "-", a Lua pattern
    -- quantifier, so an unescaped match silently finds nothing.
    local escaped = name:gsub("(%W)", "%%%1")
    for line in (toc .. "\n"):gmatch("([^\n]*)\n") do
        local value = (line:gsub("%s+$", "")):match("^##%s*" .. escaped .. ":%s*(.*)$")
        if value then return value end
    end
    return nil
end

-- Every file the TOC loads, in order, as written: each line that is neither
-- blank nor a `#` comment/directive. Any extension, so a stray XML entry
-- can't hide.
function H.tocFiles()
    return Kit.tocLines(TOC)
end

return H
