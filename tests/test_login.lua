------------------------------------------------------------
-- test_login.lua - the day Blizzard fixes SavedVariables, on a new build.
--
-- A session whose StakeoutDB arrives with svLoadCheck set really read the
-- file: no settings notice, the list is kept. A build other than
-- MEASURED_ON_BUILD gets a one-line note, in a development copy only: a
-- release keeps quiet, since what flags an addon out of date is the TOC's
-- Interface number and the note is for whoever re-measures.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

WoW.build = "70123"
WoW.version = "dev"
local T = WoW.loadAddon({ savedDB = { svLoadCheck = 3, npcList = { "Mother Fang" }, markerIndex = 8 } })

H.eq(T.settingsLoaded(), true, "svLoadCheck arrived: settings loaded")
H.eq(StakeoutDB.svLoadCheck, 4, "and it is counted on")
H.eq(StakeoutDB.npcList[1], "Mother Fang", "the saved list is kept")
H.eq(StakeoutDB.markerIndex, 8, "a saved setting is not overwritten by its default")
H.eq(StakeoutDB.soundChoice, "Raid Warning", "a missing setting gets its default")
H.check(not WoW.chat():find("doesn't reload saved settings", 1, true), "no settings notice once they load")
H.check(WoW.chat():find("Tested on client build " .. T.MEASURED_ON_BUILD .. "; this is 70123", 1, true),
    "a different build gets the note in a development copy")

local NOTE = "Tested on client build"

-- An unpackaged checkout still carries the packager's token: also a
-- development copy.
WoW.reset()
WoW.build, WoW.version = "70123", "@project-version@"
WoW.loadAddon({ savedDB = { svLoadCheck = 3 } })
H.check(WoW.chat():find(NOTE, 1, true), "an unpackaged checkout gets the note too")

-- A release keeps quiet on any build.
WoW.reset()
WoW.build, WoW.version = "70123", "2.1.0"
WoW.loadAddon({ savedDB = { svLoadCheck = 3 } })
H.check(WoW.chat():find("Loaded.", 1, true), "the release logged in")
H.check(not WoW.chat():find(NOTE, 1, true), "a release never shows the build note: " .. WoW.chat())

-- And a development copy on the measured build has nothing to say.
WoW.reset()
WoW.version = "dev"
WoW.loadAddon({ savedDB = { svLoadCheck = 3 } })
H.check(not WoW.chat():find(NOTE, 1, true), "no note on the measured build")

H.done("test_login")
