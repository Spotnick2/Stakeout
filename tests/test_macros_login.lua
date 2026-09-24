------------------------------------------------------------
-- test_macros_login.lua - sessions that start with a Stakeout List macro.
--
-- SavedVariables come back empty (this client); the macro holds the list.
-- It must be restored at login without a click, restoring twice must not
-- duplicate, a late macro load must still restore, and once restored a macro
-- event must not bring back a name removed in combat.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local MARK = "#stakeout"
local function fresh()
    StakeoutDB, Stakeout = nil, nil   -- a new session: the addon's globals start over
    dofile("tests/wow_stubs.lua")     -- and so does the client (events, frames, macros)
end

------------------------------------------------------------
-- Macros present at login
------------------------------------------------------------
WoW.SetMacro("Stakeout List", MARK .. "\n/stakeout add Mother Fang; Fedfennel")
WoW.SetMacro("Stakeout List 2", MARK .. "\n/stakeout add Gruff Swiftbite")
local T = WoW.loadAddon()

H.eq(T.macroMode(), true, "an existing Stakeout List macro turns macro mode on")
H.eq(#StakeoutDB.npcList, 3, "both macros are read back")
H.eq(StakeoutDB.npcList[1], "Mother Fang", "in order")
H.eq(StakeoutDB.npcList[3], "Gruff Swiftbite", "including the second macro")
H.check(WoW.chat():find("Restored 3 NPCs from your Stakeout List macro", 1, true), "the player is told")
H.check(not WoW.chat():find("doesn't reload saved settings", 1, true),
    "no settings-bug notice when the macro brought the list back")

WoW.fire("UPDATE_MACROS")
H.eq(#StakeoutDB.npcList, 3, "another restore attempt adds nothing twice")
H.eq(#WoW.macros, 1, "the restore writes the list back: three names fit one macro, so Stakeout List 2 goes")
H.eq(WoW.macroBody("Stakeout List"), MARK .. "\n/stakeout add Mother Fang; Fedfennel; Gruff Swiftbite",
    "and Stakeout List holds all of it")

SlashCmdList.STAKEOUT("remove Fedfennel")
H.eq(WoW.macroBody("Stakeout List"), MARK .. "\n/stakeout add Mother Fang; Gruff Swiftbite", "the macro follows the change")
H.eq(WoW.macroBody("Stakeout List 2"), nil, "and the second macro is no longer needed")

-- Once restored, a macro event must not re-read a macro whose write is
-- still waiting for combat to end.
WoW.inCombat = true
SlashCmdList.STAKEOUT("remove Mother Fang")
H.eq(WoW.macroBody("Stakeout List"), MARK .. "\n/stakeout add Mother Fang; Gruff Swiftbite", "in combat the macro is stale")
WoW.fire("UPDATE_MACROS")
H.eq(#StakeoutDB.npcList, 1, "a macro event in combat doesn't bring the removed name back")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(WoW.macroBody("Stakeout List"), MARK .. "\n/stakeout add Gruff Swiftbite", "combat ends: the macro catches up")

------------------------------------------------------------
-- Macros that load after PLAYER_LOGIN, after an early empty update
-- (PR #12 review, P2)
------------------------------------------------------------
fresh()
local T2 = WoW.loadAddon()
H.eq(#StakeoutDB.npcList, 0, "no macro at login yet")
WoW.fire("UPDATE_MACROS")                     -- an early update: still nothing
WoW.SetMacro("Stakeout List", MARK .. "\n/stakeout add Mother Fang")
WoW.fire("UPDATE_MACROS")                     -- the load
H.eq(StakeoutDB.npcList[1], "Mother Fang", "an early empty update doesn't use up the restore")
H.eq(T2.macroMode(), true, "and macro mode is on")
-- A late restore must end the listening too, or the stale-macro case returns.
WoW.inCombat = true
SlashCmdList.STAKEOUT("remove Mother Fang")
WoW.fire("UPDATE_MACROS")
H.eq(#StakeoutDB.npcList, 0, "after a late restore, a macro event in combat doesn't bring a removed name back")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")

------------------------------------------------------------
-- A player's same-named macro listed first doesn't hide ours
-- (PR #12 review, P1: GetMacroIndexByName returns only one of them)
------------------------------------------------------------
fresh()
WoW.SetMacro("Stakeout List", "/cast Hunter's Mark")
WoW.SetMacro("Stakeout List", MARK .. "\n/stakeout add Hidden Rare")
local T3 = WoW.loadAddon()
H.eq(StakeoutDB.npcList[1], "Hidden Rare", "ours is found behind the player's macro of the same name")
H.eq(T3.macroMode(), true, "macro mode is on")
H.eq(WoW.macros[1].body, "/cast Hunter's Mark", "the player's macro is untouched")

-- A player's own export macro (no marker) is not read as ours.
fresh()
WoW.SetMacro("Stakeout List", "/stakeout add Pasted By Hand")
local T4 = WoW.loadAddon()
H.eq(#StakeoutDB.npcList, 0, "a player's export macro isn't restored as ours")
H.eq(T4.macroMode(), false, "and doesn't turn macro mode on")

------------------------------------------------------------
-- /code-review findings on PR #12
------------------------------------------------------------

-- 1. Macros load late: no misleading notice before they arrive, and a
--    `/stakeout macro on` typed before they load doesn't lose the list.
fresh()
WoW.loadAddon()
H.check(not WoW.chat():find("/stakeout macro on", 1, true),
    "macros not loaded yet: the notice waits instead of offering a macro that may be on its way")
SlashCmdList.STAKEOUT("macro on")                 -- typed before the real macro loads: an empty copy
WoW.SetMacro("Stakeout List", MARK .. "\n/stakeout add Mother Fang; Fedfennel")   -- the real one arrives
WoW.fire("UPDATE_MACROS")
SlashCmdList.STAKEOUT("add Gruff Swiftbite")      -- the next write folds the two copies
H.eq(WoW.macroCount("Stakeout List"), 1, "the two copies are folded into one")
local folded = WoW.macroBody("Stakeout List") or ""
for _, n in ipairs({ "Mother Fang", "Fedfennel", "Gruff Swiftbite" }) do
    H.check(folded:find(n, 1, true), "no name from either copy is lost: " .. n)
end

-- A player who has macros, none of them ours: the notice comes once macros
-- are known loaded, and the listening stops.
fresh()
WoW.SetMacro("Heal", "/cast Heal")
WoW.loadAddon()
H.check(WoW.chat():find("/stakeout macro on", 1, true), "macros loaded, none ours: the notice is shown at login")
WoW.messages = {}
WoW.fire("UPDATE_MACROS")
H.check(not WoW.chat():find("/stakeout macro on", 1, true), "only once")

-- 2. Names added before a late restore are written into the macro.
fresh()
WoW.loadAddon()
SlashCmdList.STAKEOUT("add Pasted Rare")          -- before the macros load: macro mode still off
WoW.SetMacro("Stakeout List", MARK .. "\n/stakeout add Mother Fang")
WoW.fire("UPDATE_MACROS")
H.eq(WoW.macroBody("Stakeout List"), MARK .. "\n/stakeout add Pasted Rare; Mother Fang",
    "the restore writes back names added before it")

-- 5. A too-long name in a macro isn't restored (it could never fit back).
fresh()
WoW.SetMacro("Stakeout List", MARK .. "\n/stakeout add " .. string.rep("z", 150) .. "; Mother Fang")
WoW.loadAddon()
H.eq(#StakeoutDB.npcList, 1, "an over-long name from a macro is skipped")
H.eq(StakeoutDB.npcList[1], "Mother Fang", "the rest is restored")
H.check(#WoW.macroBody("Stakeout List") <= 255, "and the macro written back fits")

H.done("test_macros_login")
