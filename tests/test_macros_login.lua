------------------------------------------------------------
-- test_macros_login.lua - a session that starts with a Stakeout List macro.
--
-- SavedVariables come back empty (this client); the macro holds the list.
-- The list must be restored at login without a click, and restoring twice
-- (PLAYER_LOGIN, then UPDATE_MACROS once macros load) must not duplicate.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

WoW.SetMacro("Stakeout List", "/stakeout add Mother Fang; Fedfennel")
WoW.SetMacro("Stakeout List 2", "/stakeout add Gruff Swiftbite")
local T = WoW.loadAddon()

H.eq(T.macroMode(), true, "an existing Stakeout List macro turns macro mode on")
H.eq(#StakeoutDB.npcList, 3, "both macros are read back")
H.eq(StakeoutDB.npcList[1], "Mother Fang", "in order")
H.eq(StakeoutDB.npcList[3], "Gruff Swiftbite", "including the second macro")
H.check(WoW.chat():find("Restored 3 NPCs from your Stakeout List macro", 1, true), "the player is told")
H.check(not WoW.chat():find("doesn't reload saved settings", 1, true),
    "no settings-bug notice when the macro brought the list back")

WoW.fire("UPDATE_MACROS")
H.eq(#StakeoutDB.npcList, 3, "a second restore (macros loaded) adds nothing twice")
H.eq(#WoW.macros, 2, "and writes no new macros")

-- UPDATE_MACROS is handled once; later ones are our own writes echoing.
SlashCmdList.STAKEOUT("remove Fedfennel")
WoW.fire("UPDATE_MACROS")
H.eq(#StakeoutDB.npcList, 2, "a later UPDATE_MACROS doesn't bring a removed name back")
H.eq(WoW.macroBody("Stakeout List"), "/stakeout add Mother Fang; Gruff Swiftbite", "the macro follows the change")
H.eq(WoW.macroBody("Stakeout List 2"), nil, "and the second macro is no longer needed")

-- The case that guard is for: a name removed in combat, so the macro still
-- holds it until combat ends. A macro event meanwhile (any addon, or the
-- player editing a macro) must not restore the removed name.
WoW.inCombat = true
SlashCmdList.STAKEOUT("remove Mother Fang")
H.eq(WoW.macroBody("Stakeout List"), "/stakeout add Mother Fang; Gruff Swiftbite", "in combat the macro is stale")
WoW.fire("UPDATE_MACROS")
H.eq(#StakeoutDB.npcList, 1, "a macro event in combat doesn't bring the removed name back")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(WoW.macroBody("Stakeout List"), "/stakeout add Gruff Swiftbite", "combat ends: the macro catches up")

-- Macros that load only after PLAYER_LOGIN
StakeoutDB, Stakeout = nil, nil     -- a new session: the addon's globals start over
dofile("tests/wow_stubs.lua")       -- and so does the client (events, frames, macros)
local T2 = WoW.loadAddon()
H.eq(#StakeoutDB.npcList, 0, "no macro at login yet")
WoW.SetMacro("Stakeout List", "/stakeout add Mother Fang")
WoW.fire("UPDATE_MACROS")
H.eq(StakeoutDB.npcList[1], "Mother Fang", "the list is restored when the client reports its macros")
H.eq(T2.macroMode(), true, "and macro mode is on")

H.done("test_macros_login")
