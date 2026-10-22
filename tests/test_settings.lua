------------------------------------------------------------
-- test_settings.lua - the settings write path, the load check, the login
-- notices, the nameplate range, and event registration reporting.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

------------------------------------------------------------
-- Every write to StakeoutDB is inside the config-owner region
------------------------------------------------------------
-- Every Lua file the TOC loads, not only the core: a second file writing
-- StakeoutDB directly would bypass the owner as surely as the core could.
local source = assert(H.readFile("Stakeout.lua"))
local inOwner, owners, offenders = false, 0, {}
local scanned = 0
for _, file in ipairs(H.tocFiles()) do
    if file:match("%.lua$") then
        scanned = scanned + 1
        local lineNo = 0
        for line in (assert(H.readFile(file)) .. "\n"):gmatch("([^\n]*)\n") do
            lineNo = lineNo + 1
            if line:find("-- config-owner: begin", 1, true) then inOwner = true owners = owners + 1
            elseif line:find("-- config-owner: end", 1, true) then inOwner = false
            elseif not inOwner then
                local code = line:gsub("%-%-.*$", "")
                if code:find("StakeoutDB%.[%w_]+%s*=[^=]") or code:find("StakeoutDB%[[^%]]*%]%s*=[^=]")
                    or code:find("StakeoutDB%.[%w_]+%[[^%]]*%]%s*=[^=]")
                    or code:find("tinsert%(%s*StakeoutDB") or code:find("tremove%(%s*StakeoutDB")
                    or code:find("wipe%(%s*StakeoutDB") or code:find("StakeoutDB%s*=[^=]") then
                    offenders[#offenders + 1] = file .. ":" .. lineNo .. ": " .. line
                end
            end
        end
        H.check(not inOwner, file .. " closes its config-owner region")
        inOwner = false
    end
end
H.check(scanned >= 2, "the scan read every TOC Lua file (" .. scanned .. ")")
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
H.eq(StakeoutDB.questTargets, false, "defaults: quest targets off (experimental)")
H.eq(StakeoutDB.questOther, false, "defaults: other quest units off")
H.eq(type(StakeoutDB.questMutes), "table", "defaults: no quest mutes")
H.eq(next(StakeoutDB.questMutes), nil, "...an empty table")
-- The mutes are written only by the owner's functions (ns.core exports them).
H.eq(WoW.ns.core.SetQuestMute("q818", true), true, "a quest mute")
H.eq(StakeoutDB.questMutes.q818, true, "...is written")
H.eq(WoW.ns.core.SetQuestMute("q818:c3106:3106", true), true, "a target mute")
H.eq(WoW.ns.core.SetQuestMute("q818:", true), false, "a malformed key is refused")
H.eq(WoW.ns.core.SetQuestMute(818, true), false, "...and a number")
H.eq(WoW.ns.core.PruneQuestMutes({ [1] = true }), 2, "pruning drops both mutes of a quest that left")
H.eq(next(StakeoutDB.questMutes), nil, "...leaving none")
WoW.flushTimers()   -- no macros at all: the notice waits for the fallback timer
H.check(WoW.chat():find("doesn't reload saved settings", 1, true), "the settings bug is said at login")
H.check(not WoW.chat():find("Tested on client build", 1, true), "no build note on the measured build")

-- The default list is a copy, not the defaults table itself.
SlashCmdList.STAKEOUT("add Mother Fang")
SlashCmdList.STAKEOUT("clear")
SlashCmdList.STAKEOUT("add Fedfennel")
H.eq(#StakeoutDB.npcList, 1, "the live list is its own table")

------------------------------------------------------------
-- Nameplate range: left alone. Plates appear at about 40 yd on this client
-- whatever the CVar says (FOREVER-PROBE.md §7), so Stakeout no longer sets it.
------------------------------------------------------------
H.eq(WoW.cvars.nameplateMaxDistance, "45.000000", "the nameplate range is never touched at load")
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(WoW.cvars.nameplateMaxDistance, "45.000000", "nor when combat ends")
H.eq(T.ApplyNameplateDistance, nil, "there is no nameplate range code left")

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
H.check(not code:find("nameplateMaxDistance", 1, true), "the nameplate range CVar is never set (it changed nothing)")

-- A profile from before keeps no trace of the removed option.
WoW.events = {}
WoW.loadAddon({ savedDB = { svLoadCheck = 1, maxNameplateDist = true } })
H.eq(StakeoutDB.maxNameplateDist, nil, "an old saved maxNameplateDist is dropped at load")

H.done("test_settings")
