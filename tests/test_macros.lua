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
eq(T.macroMode(), false, "off until the player turns it on")
slash("add Mother Fang")
eq(#WoW.macros, 0, "adding a name while off creates no macro")
-- No macros at all: nothing says they've loaded, so the notice comes from
-- the timer fallback.
WoW.flushTimers()
check(WoW.chatText():find("/stakeout macro on", 1, true), "the login notice offers the macro option")

------------------------------------------------------------
-- On: the list goes into one macro and follows every change
------------------------------------------------------------
slash("macro on")
eq(T.macroMode(), true, "on")
eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang"), "the current list is written at once, under the marker")
slash("add Fedfennel; Gruff Swiftbite")
eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang; Fedfennel; Gruff Swiftbite"), "adds are written")
slash("remove Fedfennel")
eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang; Gruff Swiftbite"), "removes are written")
slash("clear")
eq(WoW.macroBody(LIST), MARK, "an empty list keeps the macro (the setting): just the marker")
check(MARK:sub(1, 1) == "#", "the marker is a '#' line, ignored when the macro runs (a '--' line would be said in chat)")
eq(#WoW.macros, 1, "one macro, never a duplicate")

------------------------------------------------------------
-- A long list spills into more macros; shrinking deletes the extra ones
------------------------------------------------------------
local long = {}
for i = 1, 20 do long[i] = string.format("Some Long Named Rare Number %02d", i) end
slash("add " .. table.concat(long, "; "))
check(WoW.macroBody(LIST2) ~= nil, "a list over one macro uses Stakeout List 2")
for _, name in ipairs({ LIST, LIST2 }) do
    local b = WoW.macroBody(name)
    check(#b <= 255, name .. " fits a macro, marker included (" .. #b .. ")")
end
slash("clear")
eq(WoW.macroBody(LIST2), nil, "shrinking deletes the macros no longer needed")

-- More than three macros' worth: the names that don't fit are named.
local huge = {}
for i = 1, 40 do huge[i] = string.format("Some Long Named Rare Number %02d", i) end
WoW.chat = {}
slash("add " .. table.concat(huge, "; "))
check(WoW.macroBody(LIST3) ~= nil, "up to three macros")
check(WoW.chatText():find("won't come back after a restart", 1, true), "overflow is reported")
check(WoW.chatText():find("Some Long Named Rare Number 40", 1, true), "naming what was left out")
slash("clear")

------------------------------------------------------------
-- Combat: macros can't be written; the change waits for combat to end
------------------------------------------------------------
WoW.combat = true
local ok, err = pcall(slash, "add Mother Fang")
check(ok, "adding in combat doesn't touch macros (" .. tostring(err) .. ")")
eq(WoW.macroBody(LIST), MARK, "not yet written")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
eq(WoW.macroBody(LIST), body("/stakeout add Mother Fang"), "written when combat ends")

WoW.combat = true
WoW.chat = {}
slash("macro off")
check(WoW.chatText():find("can't be changed in combat", 1, true), "turning it off in combat is refused, with a reason")
eq(T.macroMode(), true, "and it stays on")
WoW.combat = false

------------------------------------------------------------
-- Off: the macros are deleted (that is the setting)
------------------------------------------------------------
slash("macro off")
eq(T.macroMode(), false, "off")
eq(#WoW.macros, 0, "the Stakeout List macros are deleted")

------------------------------------------------------------
-- Player macros are never touched (PR #12 review, P1)
------------------------------------------------------------
-- An unrelated macro that happens to have the name.
WoW.SetMacro(LIST, "/cast Hunter's Mark")
WoW.chat = {}
slash("macro on")
eq(WoW.macroBody(LIST), "/cast Hunter's Mark", "a foreign macro named Stakeout List is left alone")
eq(WoW.macroCount(LIST), 1, "and gets no confusing twin")
eq(T.macroMode(), false, "macro mode doesn't claim it")
check(WoW.chatText():find("Couldn't write the Stakeout List macro", 1, true), "the player is told why")
slash("macro off")
eq(WoW.macroBody(LIST), "/cast Hunter's Mark", "turning it off doesn't delete the player's macro")
WoW.macros = {}

-- The player's own macro made from Export: same name, a `/stakeout add` body,
-- but no marker. Not ours.
WoW.SetMacro(LIST, "/stakeout add Mother Fang")
slash("macro on")
eq(WoW.macroBody(LIST), "/stakeout add Mother Fang", "a player's export macro isn't overwritten")
slash("macro off")
eq(WoW.macroBody(LIST), "/stakeout add Mother Fang", "or deleted")
WoW.macros = {}

-- An account macro with the name is not a character macro and not ours.
WoW.SetAccountMacro(LIST, body("/stakeout add Account Rare"))
slash("macro on")
eq(WoW.accountMacros[1].body, body("/stakeout add Account Rare"), "account macros are never written")
eq(WoW.macroCount(LIST), 1, "ours is a character macro")
slash("macro off")
eq(#WoW.accountMacros, 1, "account macros are never deleted")
WoW.accountMacros = {}

-- Two of ours with one name (duplicates are allowed): writing keeps one.
WoW.SetMacro(LIST, body("/stakeout add Old"))
WoW.SetMacro(LIST, body("/stakeout add Older"))
slash("macro on")
eq(WoW.macroCount(LIST), 1, "duplicate copies of ours are folded into one")
slash("macro off")
eq(#WoW.macros, 0, "and off deletes every copy of ours")

------------------------------------------------------------
-- The longest name accepted still fits one marked macro (PR #12 follow-up)
------------------------------------------------------------
slash("macro on")
local longest = string.rep("x", T.NAME_MAX)
slash("add " .. longest)
check(#WoW.macroBody(LIST) <= 255, "a NAME_MAX-long name fits with the marker (" .. #WoW.macroBody(LIST) .. ")")
WoW.chat = {}
slash("add " .. string.rep("y", 232))
check(WoW.chatText():find("Too long to be an NPC name", 1, true), "a longer one is refused, with a reason")
check(not WoW.macroBody(LIST):find("yyyy", 1, true), "and never reaches the macro")
slash("macro off")
slash("clear")

------------------------------------------------------------
-- /code-review findings on PR #12
------------------------------------------------------------

-- 3. Stakeout List can't be written (a player's macro has the name): no
--    orphan Stakeout List 2/3 are left behind, even for a long list.
slash("add " .. table.concat(long, "; "))
WoW.SetMacro(LIST, "/cast Hunter's Mark")
slash("macro on")
eq(T.macroMode(), false, "Stakeout List blocked: off")
eq(WoW.macroBody(LIST2), nil, "and no Stakeout List 2 left behind")
eq(#WoW.macros, 1, "only the player's macro")
WoW.macros = {}
slash("clear")

-- 4. A change in combat says it waits for combat to end (a session that
--    ends before then loses it) - once, not per change.
slash("macro on")
WoW.combat = true
WoW.chat = {}
slash("add Mother Fang")
slash("add Fedfennel")
local _, waits = WoW.chatText():gsub("will be updated when combat ends", "")
eq(waits, 1, "the wait is said once")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
slash("clear")

-- 6. A warning is said when it changes, not on every list change.
slash("add " .. table.concat(huge, "; "))
WoW.chat = {}
slash("add One More")
slash("add Another One")
check(not WoW.chatText():find("won't come back after a restart", 1, true),
    "the overflow warning isn't repeated on every add")
slash("macro off")
slash("clear")

-- 10. The too-long message never cuts a UTF-8 character in half.
WoW.chat = {}
slash("add a" .. string.rep("\208\150", 60))     -- "a" + 60 x "Ж": byte 40 falls mid-character
local msg = WoW.chat[#WoW.chat] or ""
local clipped = msg:match("characters%):|r (.-)%.%.%.$") or ""
check(clipped ~= "" and not clipped:find("[\192-\255]$"), "the clipped name ends on a whole character")
-- Follow-up review, P3: a character that ends exactly at the cut is kept.
WoW.chat = {}
slash("add " .. string.rep("a", 38) .. string.rep("\208\150", 40))   -- "Ж" occupies bytes 39-40
msg = WoW.chat[#WoW.chat] or ""
clipped = msg:match("characters%):|r (.-)%.%.%.$") or ""
eq(#clipped, 40, "a whole character at the boundary is kept")

------------------------------------------------------------
-- Full character macro slots
------------------------------------------------------------
WoW.macroSlots = 0
WoW.chat = {}
slash("macro on")
eq(T.macroMode(), false, "no free slot: stays off")
check(WoW.chatText():find("slots may be full", 1, true), "and says why")
WoW.macroSlots = 18

done("test_macros")
