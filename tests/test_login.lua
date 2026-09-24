------------------------------------------------------------
-- test_login.lua - the day Blizzard fixes SavedVariables, on a new build.
--
-- A session whose StakeoutDB arrives with svLoadCheck set really read the
-- file: no settings notice, the list is kept. A build other than
-- MEASURED_ON_BUILD gets a one-line note.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

WoW.build = "70123"
local T = WoW.loadAddon({ savedDB = { svLoadCheck = 3, npcList = { "Mother Fang" }, markerIndex = 8 } })

H.eq(T.settingsLoaded(), true, "svLoadCheck arrived: settings loaded")
H.eq(StakeoutDB.svLoadCheck, 4, "and it is counted on")
H.eq(StakeoutDB.npcList[1], "Mother Fang", "the saved list is kept")
H.eq(StakeoutDB.markerIndex, 8, "a saved setting is not overwritten by its default")
H.eq(StakeoutDB.soundChoice, "Raid Warning", "a missing setting gets its default")
H.check(not WoW.chat():find("doesn't reload saved settings", 1, true), "no settings notice once they load")
H.check(WoW.chat():find("Tested on client build " .. T.MEASURED_ON_BUILD .. "; this is 70123", 1, true),
    "a different build gets the note")

H.done("test_login")
