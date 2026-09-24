------------------------------------------------------------
-- test_macros.lua - the watch list kept in character macros (#5).
--
-- SavedVariables never load back on this client; character macros survive a
-- restart. Once turned on, every list change is written to "Stakeout List"
-- (and "Stakeout List 2"/"3" when it doesn't fit). Each body is the
-- "#stakeout" marker, then a working `/stakeout add` line. The marker is what
-- makes a macro Stakeout's: a player's own macro, even one with the same name
-- and a `/stakeout add` body pasted from Export, is never edited or deleted.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T = WoW.loadAddon()
local slash = SlashCmdList.STAKEOUT
local LIST, LIST2, LIST3 = T.MACRO_NAMES[1], T.MACRO_NAMES[2], T.MACRO_NAMES[3]
local MARK = T.MACRO_MARK
local function body(line) return MARK .. "\n" .. line end

------------------------------------------------------------
-- Off by default: nothing is written to the player's macros
------------------------------------------------------------
H.eq(T.macroMode(), false, "off until the player turns it on")
slash("add Mother Fang")
H.eq(#WoW.macros, 0, "adding a name while off creates no macro")
H.check(WoW.chat():find("/stakeout macro on", 1, true), "the login notice offers the macro option")

------------------------------------------------------------
-- On: the list goes into one macro and follows every change
------------------------------------------------------------
slash("macro on")
H.eq(T.macroMode(), true, "on")
H.eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang"), "the current list is written at once, under the marker")
slash("add Fedfennel; Gruff Swiftbite")
H.eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang; Fedfennel; Gruff Swiftbite"), "adds are written")
slash("remove Fedfennel")
H.eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang; Gruff Swiftbite"), "removes are written")
slash("clear")
H.eq(WoW.macroBody(LIST), MARK, "an empty list keeps the macro (the setting): just the marker")
H.check(MARK:sub(1, 1) == "#", "the marker is a '#' line, ignored when the macro runs (a '--' line would be said in chat)")
H.eq(#WoW.macros, 1, "one macro, never a duplicate")

------------------------------------------------------------
-- A long list spills into more macros; shrinking deletes the extra ones
------------------------------------------------------------
local long = {}
for i = 1, 20 do long[i] = string.format("Some Long Named Rare Number %02d", i) end
slash("add " .. table.concat(long, "; "))
H.check(WoW.macroBody(LIST2) ~= nil, "a list over one macro uses Stakeout List 2")
for _, name in ipairs({ LIST, LIST2 }) do
    local b = WoW.macroBody(name)
    H.check(#b <= 255, name .. " fits a macro, marker included (" .. #b .. ")")
end
slash("clear")
H.eq(WoW.macroBody(LIST2), nil, "shrinking deletes the macros no longer needed")

-- More than three macros' worth: the names that don't fit are named.
local huge = {}
for i = 1, 40 do huge[i] = string.format("Some Long Named Rare Number %02d", i) end
WoW.messages = {}
slash("add " .. table.concat(huge, "; "))
H.check(WoW.macroBody(LIST3) ~= nil, "up to three macros")
H.check(WoW.chat():find("won't come back after a restart", 1, true), "overflow is reported")
H.check(WoW.chat():find("Some Long Named Rare Number 40", 1, true), "naming what was left out")
slash("clear")

------------------------------------------------------------
-- Combat: macros can't be written; the change waits for combat to end
------------------------------------------------------------
WoW.inCombat = true
local ok, err = pcall(slash, "add Mother Fang")
H.check(ok, "adding in combat doesn't touch macros (" .. tostring(err) .. ")")
H.eq(WoW.macroBody(LIST), MARK, "not yet written")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang"), "written when combat ends")

WoW.inCombat = true
WoW.messages = {}
slash("macro off")
H.check(WoW.chat():find("can't be changed in combat", 1, true), "turning it off in combat is refused, with a reason")
H.eq(T.macroMode(), true, "and it stays on")
WoW.inCombat = false

------------------------------------------------------------
-- Off: the macros are deleted (that is the setting)
------------------------------------------------------------
slash("macro off")
H.eq(T.macroMode(), false, "off")
H.eq(#WoW.macros, 0, "the Stakeout List macros are deleted")

------------------------------------------------------------
-- Player macros are never touched (PR #12 review, P1)
------------------------------------------------------------
-- An unrelated macro that happens to have the name.
WoW.SetMacro(LIST, "/cast Hunter's Mark")
WoW.messages = {}
slash("macro on")
H.eq(WoW.macroBody(LIST), "/cast Hunter's Mark", "a foreign macro named Stakeout List is left alone")
H.eq(WoW.macroCount(LIST), 1, "and gets no confusing twin")
H.eq(T.macroMode(), false, "macro mode doesn't claim it")
H.check(WoW.chat():find("Couldn't write the Stakeout List macro", 1, true), "the player is told why")
slash("macro off")
H.eq(WoW.macroBody(LIST), "/cast Hunter's Mark", "turning it off doesn't delete the player's macro")
WoW.macros = {}

-- The player's own macro made from Export: same name, a `/stakeout add` body,
-- but no marker. Not ours.
WoW.SetMacro(LIST, "/stakeout add Mother Fang")
slash("macro on")
H.eq(WoW.macroBody(LIST), "/stakeout add Mother Fang", "a player's export macro isn't overwritten")
slash("macro off")
H.eq(WoW.macroBody(LIST), "/stakeout add Mother Fang", "or deleted")
WoW.macros = {}

-- An account macro with the name is not a character macro and not ours.
WoW.SetAccountMacro(LIST, body("/stakeout add Account Rare"))
slash("macro on")
H.eq(WoW.accountMacros[1].body, body("/stakeout add Account Rare"), "account macros are never written")
H.eq(WoW.macroCount(LIST), 1, "ours is a character macro")
slash("macro off")
H.eq(#WoW.accountMacros, 1, "account macros are never deleted")
WoW.accountMacros = {}

-- Two of ours with one name (duplicates are allowed): writing keeps one.
WoW.SetMacro(LIST, body("/stakeout add Old"))
WoW.SetMacro(LIST, body("/stakeout add Older"))
slash("macro on")
H.eq(WoW.macroCount(LIST), 1, "duplicate copies of ours are folded into one")
slash("macro off")
H.eq(#WoW.macros, 0, "and off deletes every copy of ours")

------------------------------------------------------------
-- Full character macro slots
------------------------------------------------------------
WoW.macroSlots = 0
WoW.messages = {}
slash("macro on")
H.eq(T.macroMode(), false, "no free slot: stays off")
H.check(WoW.chat():find("slots may be full", 1, true), "and says why")
WoW.macroSlots = 18

H.done("test_macros")
