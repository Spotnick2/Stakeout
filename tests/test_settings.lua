------------------------------------------------------------
-- test_settings.lua - the settings write path, the load check, the login
-- notices, the nameplate range, and event registration reporting.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

------------------------------------------------------------
-- Every write to StakeoutDB is inside the config-owner region
------------------------------------------------------------
local source = assert(H.readFile("Stakeout.lua"))
local inOwner, owners, offenders = false, 0, {}
local lineNo = 0
for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lineNo = lineNo + 1
    if line:find("-- config-owner: begin", 1, true) then inOwner = true owners = owners + 1
    elseif line:find("-- config-owner: end", 1, true) then inOwner = false
    elseif not inOwner then
        local code = line:gsub("%-%-.*$", "")
        if code:find("StakeoutDB%.[%w_]+%s*=[^=]") or code:find("StakeoutDB%[[^%]]*%]%s*=[^=]")
            or code:find("tinsert%(%s*StakeoutDB") or code:find("tremove%(%s*StakeoutDB")
            or code:find("wipe%(%s*StakeoutDB") or code:find("StakeoutDB%s*=[^=]") then
            offenders[#offenders + 1] = lineNo .. ": " .. line
        end
    end
end
H.eq(owners, 1, "exactly one config-owner region; add another only on purpose")
H.eq(#offenders, 0, "StakeoutDB is written only through the owner region: " .. table.concat(offenders, " | "))

-- svLoadCheck must never be defaulted, or it could never tell a real load.
local defaultsBlock = source:match("local defaults = (%b{})")
H.check(defaultsBlock and not defaultsBlock:find("svLoadCheck"), "svLoadCheck is not in the defaults")

------------------------------------------------------------
-- Fresh session (what this client always gives): notice + defaults
------------------------------------------------------------
local T = WoW.loadAddon()
H.eq(T.settingsLoaded(), false, "nothing came back from disk")
H.eq(StakeoutDB.svLoadCheck, 1, "the sentinel is written")
H.eq(#StakeoutDB.npcList, 0, "defaults: empty watch list")
H.check(WoW.chat():find("doesn't reload saved settings", 1, true), "the settings bug is said at login")
H.check(not WoW.chat():find("Tested on client build", 1, true), "no build note on the measured build")

-- The default list is a copy, not the defaults table itself.
SlashCmdList.STAKEOUT("add Mother Fang")
SlashCmdList.STAKEOUT("clear")
SlashCmdList.STAKEOUT("add Fedfennel")
H.eq(#StakeoutDB.npcList, 1, "the live list is its own table")

------------------------------------------------------------
-- Nameplate range: raised from the default 45, never lowered
------------------------------------------------------------
H.eq(WoW.cvars.nameplateMaxDistance, "100", "the 45 default is raised")
WoW.cvars.nameplateMaxDistance = "120"
T.ApplyNameplateDistance()
H.eq(WoW.cvars.nameplateMaxDistance, "120", "a higher range is left alone")
-- The CVar is secure: in combat it waits for combat to end.
WoW.cvars.nameplateMaxDistance = "45"
WoW.inCombat = true
T.ApplyNameplateDistance()
H.eq(WoW.cvars.nameplateMaxDistance, "45", "not set in combat (secure CVar)")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(WoW.cvars.nameplateMaxDistance, "100", "set when combat ends")
StakeoutDB.maxNameplateDist = false
WoW.cvars.nameplateMaxDistance = "45"
T.ApplyNameplateDistance()
H.eq(WoW.cvars.nameplateMaxDistance, "45", "the option off leaves the CVar alone")

------------------------------------------------------------
-- Event registration: throws and refusals are both reported
------------------------------------------------------------
WoW.messages = {}
WoW.badEvents.NOT_AN_EVENT = true
local probe = CreateFrame("Frame")
T.RegisterEvents(probe, "UNIT_DIED", "NOT_AN_EVENT", "COMBAT_LOG_EVENT_UNFILTERED")
local failures = table.concat(T.eventFailures, ",")
H.check(failures:find("NOT_AN_EVENT", 1, true), "an event that throws is reported")
H.check(failures:find("COMBAT_LOG_EVENT_UNFILTERED", 1, true), "an event refused with false is reported")
H.check(not failures:find("UNIT_DIED", 1, true), "an accepted event is not")
H.check(WoW.chat():find("Could not listen for NOT_AN_EVENT", 1, true), "the player is told")
-- Code only: the comments explain why these are gone.
local code = source:gsub("%-%-[^\n]*", "")
H.check(not code:find("COMBAT_LOG_EVENT_UNFILTERED", 1, true),
    "the addon never registers the combat log (forbidden on this client)")
H.check(not code:find("SetRaidTarget", 1, true), "the addon never calls SetRaidTarget (forbidden)")
H.check(not code:find("TargetUnit", 1, true), "no proximity trick (fires for every name)")

H.done("test_settings")
