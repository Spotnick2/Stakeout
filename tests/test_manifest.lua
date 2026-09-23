------------------------------------------------------------
-- test_manifest.lua - assertions about Stakeout.toc and .pkgmeta.
--
-- Neither file is Lua, and a mistake in either is invisible until a player
-- notices: a file that doesn't load, settings stored somewhere odd, a CurseForge
-- upload attached to the wrong project, or a zip that ships the tests.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_manifest.lua
------------------------------------------------------------

local H = dofile("tests/harness.lua")

------------------------------------------------------------
-- TOC
------------------------------------------------------------

-- Only the plain TOC is read by the client; `_Forever.toc` is ignored, and a
-- suffixed file next to it would drift unnoticed.
for _, suffix in ipairs({ "_Forever", "_Camelot", "_Vanilla", "_TBC", "_Classic" }) do
    H.check(H.readFile("Stakeout" .. suffix .. ".toc") == nil,
        "Stakeout" .. suffix .. ".toc must not exist: the client reads only Stakeout.toc")
end

H.eq(H.directive("Interface"), "16001",
    "WoW: Forever 1.60.1 is interface 16001 - the %d%02d%02d form, not the transposed 11601 "
    .. "that circulates in the wild")

H.eq(H.directive("Version"), "@project-version@",
    "the packager substitutes @project-version@; deploy.ps1 rewrites it to 'dev' in the deployed copy only")

H.eq(H.directive("X-Curse-Project-ID"), "1508654",
    "Stakeout's CurseForge project (the tag webhook posts to this project)")

-- SavedVariables never load back on this client (docs/FOREVER-PROBE.md, 11),
-- per-character included. The directive stays: it is where settings will be
-- read from once Blizzard fixes the loader.
H.eq(H.directive("SavedVariablesPerCharacter"), "StakeoutDB",
    "settings are per character")

-- Every load line, whatever its extension: the client would try to load a
-- referenced file that the package doesn't carry.
local files = H.tocFiles()
H.eq(#files, 1, "the TOC loads exactly one file (the addon is a single file)")
H.eq(files[1], "Stakeout.lua", "the TOC loads Stakeout.lua")
for _, file in ipairs(files) do
    H.check(H.readFile(file) ~= nil, "the TOC loads " .. file .. ", which does not exist")
end

------------------------------------------------------------
-- .pkgmeta: what the release zip must leave out
------------------------------------------------------------

local pkgmeta = assert(H.readFile(".pkgmeta"), ".pkgmeta is missing")
H.check(pkgmeta:find("\npackage%-as: Stakeout\n") or pkgmeta:find("^package%-as: Stakeout\n"),
    ".pkgmeta packages the addon as Stakeout")

-- Only the `ignore:` block: it ends at the next line that isn't indented, so
-- an entry under a later key (`plain-copy:`) can't count as ignored.
local ignored = {}
local inIgnore = false
for line in (pkgmeta .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%S") then
        inIgnore = (line:match("^ignore:%s*$") ~= nil)
    elseif inIgnore then
        local entry = line:match("^%s+%-%s+(%S+)%s*$")
        if entry then ignored[entry] = true end
    end
end
for _, path in ipairs({ ".github", ".claude", "tests", "Tools", "docs", "AGENTS.md", "CLAUDE.md",
                        "README.md", "CHANGELOG.md" }) do
    H.check(ignored[path], ".pkgmeta must ignore " .. path .. " so it never ships to players")
end

H.check(not pkgmeta:find("externals:"), "Stakeout embeds no libraries")

H.done("test_manifest")
