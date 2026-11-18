------------------------------------------------------------
-- test_login.lua - the day Blizzard fixes SavedVariables, on a new build.
--
-- A session whose StakeoutDB arrives with svLoadCheck set really read the
-- file: no settings notice, the list is kept. A build other than
-- the last one seen (MEASURED_ON_BUILD at first) gets a one-line note, once,
-- in a development copy only: a release keeps quiet, since what flags an addon
-- out of date is the TOC's Interface number and the note is for whoever
-- re-measures.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

WoW.build = "70400"
WoW.version = "dev"
local T = WoW.loadAddon({ savedDB = { svLoadCheck = 3, npcList = { "Mother Fang" }, markerIndex = 8 } })

eq(T.settingsLoaded(), true, "svLoadCheck arrived: settings loaded")
eq(StakeoutDB.svLoadCheck, 4, "and it is counted on")
eq(StakeoutDB.npcList[1], "Mother Fang", "the saved list is kept")
eq(StakeoutDB.markerIndex, 8, "a saved setting is not overwritten by its default")
eq(StakeoutDB.soundChoice, "Raid Warning", "a missing setting gets its default")
check(not WoW.chatText():find("doesn't reload saved settings", 1, true), "no settings notice once they load")

------------------------------------------------------------
-- The build note: a development copy says once per new build.
------------------------------------------------------------

local NOTE = "Client build changed"

check(WoW.chatText():find(NOTE .. ": " .. T.MEASURED_ON_BUILD .. " -> 70400", 1, true),
    "a dev copy that has seen no build compares with MEASURED_ON_BUILD: " .. WoW.chatText())
eq(StakeoutDB.lastBuild, "70400", "and records the build")

-- Next login on the same build, settings loaded: quiet.
local saved = StakeoutDB
WoW.reset()
WoW.build, WoW.version = "70400", "dev"
WoW.loadAddon({ savedDB = saved })
check(WoW.chatText():find("Loaded.", 1, true), "logged in again")
check(not WoW.chatText():find(NOTE, 1, true), "the same build is not announced twice")

-- The client patches again: once more, from the last build seen.
saved = StakeoutDB
WoW.reset()
WoW.build, WoW.version = "70500", "dev"
WoW.loadAddon({ savedDB = saved })
check(WoW.chatText():find(NOTE .. ": 70400 -> 70500", 1, true),
    "a new build is announced from the last one seen: " .. WoW.chatText())

-- An unpackaged checkout is a development copy too.
WoW.reset()
WoW.build, WoW.version = "70400", "@project-version@"
WoW.loadAddon({ savedDB = { svLoadCheck = 3 } })
check(WoW.chatText():find(NOTE, 1, true), "an unpackaged checkout gets the note too")

-- A release keeps quiet on any build, but still records it, so a dev copy
-- deployed over it does not announce a patch the player already had.
WoW.reset()
WoW.build, WoW.version = "70400", "2.1.1"
WoW.loadAddon({ savedDB = { svLoadCheck = 3 } })
check(WoW.chatText():find("Loaded.", 1, true), "the release logged in")
check(not WoW.chatText():find(NOTE, 1, true), "a release never shows the build note: " .. WoW.chatText())
eq(StakeoutDB.lastBuild, "70400", "a release records the build")
saved = StakeoutDB
WoW.reset()
WoW.build, WoW.version = "70400", "dev"
WoW.loadAddon({ savedDB = saved })
check(not WoW.chatText():find(NOTE, 1, true), "a dev copy over a release on the same build is quiet")

-- A fresh dev copy on the measured build has nothing to say.
WoW.reset()
WoW.version = "dev"
WoW.loadAddon({ savedDB = { svLoadCheck = 3 } })
check(not WoW.chatText():find(NOTE, 1, true), "no note on the measured build")

done("test_login")
