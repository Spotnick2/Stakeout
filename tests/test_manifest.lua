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

-- ...and it substitutes keywords in EVERY file it ships, Lua included, not
-- only the TOC. A Lua comparison against the whole "@project-version@" became
-- `version == "v2.1.1"` in the released file, and every player's copy took
-- itself for a development copy (#17), which no offline test could see,
-- because they load the source, where the token is still raw. So no shipped
-- Lua file may hold a packager keyword whole; code that needs one builds it
-- from pieces. Matched by shape, because the packager has a family of them
-- (@project-revision@, @file-date-iso@, @debug@, ...).
for _, file in ipairs(H.tocFiles()) do
    local src = H.readFile(file) or ""
    local n, keyword = 0, nil
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        keyword = line:match("(@[%w%-]+@)")
        if keyword then break end
    end
    H.check(keyword == nil, file .. " holds no packager keyword the release would rewrite: "
        .. tostring(keyword) .. " at line " .. n)
end

-- The Wago Addons project: CI's `wago` job uploads each tag to the project the
-- packaged TOC names, and the Wago app matches an installed copy by it (#23).
H.eq(H.directive("X-Wago-ID"), "rNkgwjNa", "Stakeout's Wago Addons project")

H.eq(H.directive("X-Curse-Project-ID"), "1508654",
    "Stakeout's CurseForge project (the tag webhook posts to this project)")

-- SavedVariables never load back on this client (docs/FOREVER-PROBE.md, 11),
-- per-character included. The directive stays: it is where settings will be
-- read from once Blizzard fixes the loader.
-- Glass UI loads first when it is enabled, so Stakeout can follow it at its own
-- ADDON_LOADED (GlassUI docs/SUITE.md); without it, Stakeout loads as before.
H.eq(H.directive("OptionalDeps"), "GlassUI", "Glass UI, optionally, before Stakeout")

H.eq(H.directive("SavedVariablesPerCharacter"), "StakeoutDB",
    "settings are per character")

-- Every load line, whatever its extension: the client would try to load a
-- referenced file that the package doesn't carry.
-- The library first (its files run before ours, as LibStub embedding needs),
-- then the look, then the core that builds the windows with it.
local files = H.tocFiles()
H.eq(#files, 3, "the TOC loads the library, Theme.lua and Stakeout.lua")
H.eq(files[1], "Libs\\LibGlass-1.0\\LibGlass-1.0.xml", "the embedded LibGlass-1.0 loads first")
H.eq(files[2], "Theme.lua", "then Theme.lua")
H.eq(files[3], "Stakeout.lua", "then Stakeout.lua")
-- Libs/ is the packager's (.pkgmeta externals) and gitignored: not on disk here.
for i = 2, #files do
    H.check(H.readFile(files[i]) ~= nil, "the TOC loads " .. files[i] .. ", which does not exist")
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

-- One library, pinned to a tag: `latest` would ship whatever is newest, and
-- CI and deploy.ps1 read this pin. The packager's YAML reader keeps an inline
-- comment as part of a value, so none may sit on these lines.
local externals = pkgmeta:match("\nexternals:\n(.-)\n%S") or ""
H.check(externals:find("^  Libs/LibGlass%-1%.0:\n    url: https://github%.com/Spotnick2/LibGlass\n    tag: r%d+\n?$"),
    "the only external is LibGlass-1.0, from Spotnick2/LibGlass, pinned to a tag: " .. externals)
local pin = tonumber(externals:match("tag: r(%d+)") or "")
H.check(pin and pin >= 9, "the pin is r9 or later (Glass.Reflect): r" .. tostring(pin))
H.check(not pkgmeta:find("\n%s*tag:%s*latest"), "never `tag: latest`")
-- The library's own ignores don't apply to an external: what it doesn't
-- ship is named here, or it lands in players' AddOns.
for _, path in ipairs({ "tests", "docs", "Tools", "AGENTS.md", "CLAUDE.md", "README.md" }) do
    H.check(ignored["Libs/LibGlass-1.0/" .. path], ".pkgmeta must ignore Libs/LibGlass-1.0/" .. path)
end
H.check((H.readFile(".gitignore") or ""):find("\nLibs/\n", 1, true),
    ".gitignore keeps the packager's Libs/ out of the repo")

H.done("test_manifest")
