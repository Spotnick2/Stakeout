-- StakeoutProbe: a ForeverProbe module (the host loaded from its checkout).
-- Its commands run on the stubbed client and log what they read, never to
-- chat; its procedures are defined and start. A fake LibQuestieDB stands in
-- for QuestieDB (another addon's global, not a client API). Runs locally only:
-- CI sets FOREVERPROBE_OPTIONAL=1 and this file skips itself.
dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

-- ForeverProbe, as the client loads it before a dependent (GUIDE.md, section 8).
local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
local toc = io.open(root .. "/ForeverProbe.toc", "rb")
if not toc then
    if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
        Kit.skip("test_probe", "ForeverProbe is private and local; the probe tests run locally")
    end
    error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
end
local hostFiles = {}
for line in toc:read("*a"):gmatch("[^\r\n]+") do
    if line:match("%.lua$") and not line:match("^#") then hostFiles[#hostFiles + 1] = root .. "/" .. line end
end
toc:close()

-- The host's own globals and the probe's, nil until they are made.
for _, g in ipairs({ "ForeverProbe", "ForeverProbeDB", "StakeoutProbeDB", "LibQuestieDB", "Questie",
                     "SLASH_FOREVERPROBE1", "SLASH_FOREVERPROBE2" }) do
    WoW.allowGlobal(g)
end

for _, file in ipairs(hostFiles) do assert(loadfile(file))("ForeverProbe", {}) end
WoW.fire("ADDON_LOADED", "ForeverProbe")
local FP = ForeverProbe

--------------------------------------------------------------------------------
-- The client this probe reads (each function below is in the 70450 dump)
--------------------------------------------------------------------------------

WoW.quests = {
    { questID = 100, title = "Vile Familiars", rows = { { text = "0/8 Vile Familiar slain", type = "monster",
        finished = false, numFulfilled = 0, numRequired = 8 } } },
    { questID = 101, title = "Report to Orgnil", rows = {}, complete = true },
}
C_QuestLog = {}
function C_QuestLog.GetNumQuestLogEntries() return #WoW.quests, #WoW.quests end
function C_QuestLog.GetInfo(i)
    local q = WoW.quests[i]
    return q and { questID = q.questID, title = q.title, isHeader = false }
end
function C_QuestLog.GetQuestObjectives(id)
    for _, q in ipairs(WoW.quests) do if q.questID == id then return q.rows end end
    return {}
end
function C_QuestLog.IsComplete(id)
    for _, q in ipairs(WoW.quests) do if q.questID == id then return q.complete == true end end
    return false
end
function C_QuestLog.ReadyForTurnIn(id) return C_QuestLog.IsComplete(id) end
function C_QuestLog.UnitIsRelatedToActiveQuest(token) return token == "target" end

-- Durotar, 5000 x 3333 yd; the player at 52.0, 43.0.
WoW.pos = { map = 1411, x = 0.52, y = 0.43, w = 5000, h = 3333 }
C_Map = {}
function C_Map.GetBestMapForUnit() return WoW.pos.map end
function C_Map.GetPlayerMapPosition() return { GetXY = function() return WoW.pos.x, WoW.pos.y end } end
function C_Map.GetMapWorldSize() return WoW.pos.w, WoW.pos.h end
function UnitPosition() return WoW.pos.x * WoW.pos.w, WoW.pos.y * WoW.pos.h, 0, 1 end
function IsInInstance() return false, "none" end
function UnitCreatureID(token) local u = WoW.units[token] return u and u.creatureID end
function UnitCanAttack(_, token) local u = WoW.units[token] return u and not u.friendly end
function UnitReaction(token) local u = WoW.units[token] return u and (u.friendly and 5 or 2) end
function GetRaidTargetIndex() return nil end
function C_NamePlate.GetNamePlateForUnit(token) local u = WoW.units[token] return u and u.plate and {} or nil end
function debugprofilestop() return WoW.now * 1000 end

-- A QuestieDB with the provider's shape (src/api.lua, src/support/data.lua).
local NPCS = {
    [3142] = { name = "Orgnil Soulscar", spawns = { [14] = { { 52.24, 43.15 } } }, questEnds = { 101 } },
    [3101] = { name = "Vile Familiar", spawns = { [14] = { { 45, 57 }, { 46, 58 } } } },
}
local function entityOf(rows)
    return { Get = function(id, key) return rows[id] and rows[id][key] end }
end
LibQuestieDB = {
    addonName = "QuestieDB", readMode = "baked", contractVersion = 4, minSupportedContract = 4,
    RequireContract = function(n) return n == 4 end,
    Npc = entityOf(NPCS),
    Quest = entityOf({ [100] = { objectives = { { { 3101 } } } }, [101] = { finishedBy = { { 3142 } } } }),
    Item = entityOf({}), Object = entityOf({}),
    ObjectiveFirst = { killCreditObjectiveFirst = {}, itemObjectiveFirst = { [100] = true } },
    EraToForever = function(area, x, y) if area == 215 then return x * 0.8 + 7, y * 0.8 + 13 end return x, y end,
    Support = { Get = function(name)
        if name ~= "ZoneDB" then return nil end
        return { private = {
            areaIdToUiMapId = "return {\n    [14] = 1411, -- Durotar\n    [215] = 1412, -- Mulgore\n}",
            areaIdToUiMapIdOverride = "return {\n    [0] = 0, -- fail-safe\n}",
        } }
    end },
}

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local ns = {}
assert(loadfile("Tools/StakeoutProbe/StakeoutProbe.lua"))("StakeoutProbe", ns)
assert(loadfile("Tools/StakeoutProbe/Hud.lua"))("StakeoutProbe", ns)   -- the TOC's order
assert(loadfile("Tools/StakeoutProbe/Layout.lua"))("StakeoutProbe", ns)
assert(loadfile("Tools/StakeoutProbe/Alert.lua"))("StakeoutProbe", ns)
WoW.fire("ADDON_LOADED", "StakeoutProbe")
WoW.fire("PLAYER_LOGIN")
local T = ns._test
local db = StakeoutProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end

check(T.Probe.log == db.log, "its ForeverProbe log is StakeoutProbeDB.log, bound at ADDON_LOADED")
check(logged("loaded %(1 loads%)"), "loaded")
check(logged("sample PLAYER_LOGIN: 0 plates"), "the login sample")

--------------------------------------------------------------------------------
-- The area map parser: data only, all or nothing
--------------------------------------------------------------------------------

local map, n = T.parseAreaMap("return {\n    [14] = 1411, -- Durotar\n\n    -- a note\n    [2257] = 0,\n}")
eq(n, 2, "two entries")
eq(map and map[14], 1411, "14 -> 1411")
eq(map and map[2257], 0, "an explicit 0 is kept")
check(not T.parseAreaMap("return { [14] = 1411, os.exit() }"), "anything else rejects the whole string")
check(not T.parseAreaMap("{ [14] = 1411 }"), "not a `return { }`")
check(not T.parseAreaMap(nil), "not a string")
eq(T.npcIdFromGuid("Creature-0-4170-1-12-3142-0000ABCD"), 3142, "an NPC ID from a GUID")
eq(T.npcIdFromGuid("Player-4170-0A1B2C3D"), nil, "a player's GUID gives none")
eq(T.npcIdFromGuid(WoW.SECRET), nil, "a secret GUID gives none")

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000ABCD", creatureID = 3142,
    friendly = true })
for _, cmd in ipairs({ "state", "log", "unit", "plates", "spawns", "near", "questie", "mark", "walk",
                       "events on", "events off" }) do
    fp("so " .. cmd)
end
check(logged("position: map 1411 at 52%.00, 43%.00; map 5000 x 3333 yd"), "state: the position")
check(logged("Q 100 Vile Familiars: IsComplete false ReadyForTurnIn false, 1 rows"), "log: a quest")
check(logged("row 1: type monster finished false 0/8 objectiveType nil text \"0/8 Vile Familiar slain\""),
    "log: its row, raw")
check(logged("questie creature: 3101 Vile Familiar"), "log: QuestieDB's objective")
check(logged("questie finishedBy npc %[3142 Orgnil Soulscar%] object %- ; first: none")
    or logged("questie finishedBy npc %[3142 Orgnil Soulscar%]"), "log: the finisher")
check(logged("first: itemObjectiveFirst"), "log: Questie's ordering hint")
check(logged("unit target: name \"Orgnil Soulscar\" .* creatureID 3142 related true attackable false"), "unit")
check(logged("questie npc 3142: name Orgnil Soulscar, same as the client's"), "unit: QuestieDB's name matches")
check(logged("spawns in area 14 %-> uiMap 1411: 1 points %(this map%)"), "spawns: the area mapped to this map")
local nearest = logged("nearest spawn ([%d.]+) yd")
local d = tonumber(nearest and nearest:match("nearest spawn ([%d.]+) yd"))
check(d and d > 12.9 and d < 13.1, "spawns: Orgnil 13 yd away (0.24% of 5000 = 12, 0.15% of 3333 = 5): " .. tostring(d))
check(logged("turnin Orgnil Soulscar %(3142%) for Report to Orgnil"), "near: the turn-in, once complete")
check(logged("kill Vile Familiar %(3101%) for Vile Familiars"), "near: the kill target")
check(logged("RequireContract%(4%) true"), "questie: the contract")
check(logged("area map: 3 areas in"), "questie: the map parsed, with the override's entry added")
check(logged("walk: 0%.0 yd on the map, 0%.0 yd in the world"), "walk: no move")
check(logged("events: logging") and logged("events: stopped"), "events on and off")

-- A player is never logged by name.
WoW.SetUnit("target", { name = "Someone", guid = "Player-4170-0A1B2C3D", player = true })
fp("so unit")
check(logged("unit target: a player %(not logged%)"), "a player target")
check(not logged("Someone"), "...and their name isn't in the log")

-- The test button: left /targetexact, right adds /tm; never changed in combat.
fp("so button Orgnil Soulscar !8")
local b = _G.StakeoutProbeButton
check(b and b._template == "SecureActionButtonTemplate", "a secure button")
eq(b._attrs.macrotext, "/cleartarget\n/targetexact Orgnil Soulscar", "left: target by exact name")
eq(b._attrs.macrotext2, "/cleartarget\n/targetexact Orgnil Soulscar\n/tm !8", "right: and mark")
eq(#b._forClicks, 2, "both mouse edges registered")
-- A click: the secure macro runs (here: the target set by hand), then PostClick logs what it got.
b._scripts.PostClick(b, "LeftButton", true)
check(logged("click LeftButton down: target <a player> %(wanted"), "a player targeted is logged as one")
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000ABCD", creatureID = 3142,
    friendly = true })
b._scripts.PostClick(b, "RightButton", false)
check(logged("click RightButton up: target Orgnil Soulscar %(wanted Orgnil Soulscar%) plate false mark nil "
    .. "dead false unit 0000ABCD"), "a click logs the target it got, alive or not, and which one")
eq(T.state.clicks, 2, "...and counts")
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000BEEF", creatureID = 3142,
    dead = true })
b._scripts.PostClick(b, "LeftButton", true)
check(logged("dead true unit 0000BEEF"), "a corpse is logged as one")
eq(T.state.lastClick.dead, true, "...and recorded")
WoW.combat = true
fp("so button Vile Familiar")
eq(b._attrs.macrotext, "/cleartarget\n/targetexact Orgnil Soulscar", "not changed in combat")
check(logged("button: in combat"), "...saying why")
WoW.combat = false
fp("so button off")
eq(b._shown, false, "button off hides it")

--------------------------------------------------------------------------------
-- Procedures
--------------------------------------------------------------------------------

for _, name in ipairs({ "quests", "range", "hostile", "events", "core", "mulgore", "corpse", "look", "rows", "alert",
                        "tagged", "customize" }) do
    fp("steps so " .. name)
    local rec = FP.db.steps.records["StakeoutProbe/" .. name]
    eq(rec and rec.status, "active", "procedure " .. name .. " starts")
    fp("steps stop")
end

-- #94's alert procedure: the click setting it switches comes back (saved
-- once, put back on a stop), and each gesture's expected result.
do
    local A = ns._test.alert
    rawset(_G, "SetCVar", function(k, v) if k == "ActionButtonUseKeyDown" then WoW.useKeyDown = v == "1" end end)
    if type(rawget(_G, "StakeoutProbeDB")) ~= "table" then rawset(_G, "StakeoutProbeDB", {}) end
    WoW.useKeyDown = true
    A.setKeyDown(true)()
    eq(WoW.useKeyDown, false, "the switch flips ActionButtonUseKeyDown")
    A.setKeyDown(true)()
    eq(StakeoutProbeDB.alertKeyDown, true, "Back and Run again: the original stays the one saved first")
    A.restoreOn({ stopped = true })("done")
    eq(WoW.useKeyDown, false, "leaving a switched step by Next keeps it switched")
    A.restoreOn({ stopped = true })("stopped")
    eq(WoW.useKeyDown, true, "Stop puts it back")
    eq(StakeoutProbeDB.alertKeyDown, nil, "...and forgets it")
    A.setKeyDown(true)()
    local ok, err = pcall(A.snapshot)   -- the first step, after a /reload
    eq(WoW.useKeyDown, true, "a run left switched is put back by the next one's first step")
    check(not ok and tostring(err):find("Stakeout", 1, true), "...which then says what it needs: " .. tostring(err))
    A.setKeyDown(true)()
    A.restoreOn({ stopped = true, skipped = true })("skipped")
    eq(WoW.useKeyDown, true, "Skip at the restore step puts it back")
    -- The gestures: Shift added before release targets at 1 and toggles at 0.
    WoW.SetUnit("target", { name = "Some Mob", guid = "Creature-0-1-2-3-55-A" })
    WoW.useKeyDown = true
    check((A.gesture(true)()), "at 1, Shift added late: a target is right")
    check(not A.gesture(false)(), "at 1, Shift let go early: a target is wrong (it should toggle)")
    WoW.useKeyDown = false
    check(not A.gesture(true)(), "at 0, Shift added late: a target is wrong (it should toggle)")
    check((A.gesture(false)()), "at 0, Shift let go early: a target is right")
    WoW.units.target, WoW.useKeyDown = nil, true
    rawset(_G, "SetCVar", nil)
end

-- The corpse variants set the left-click macro, with the name filled in.
eq(T.aim("Pygmy Surf Crawler", 3106, "8",
    "/cleartarget\n/targetexact <name>\n/cleartarget [dead]\n/targetexact <name>"), true, "a variant is set")
eq(b._attrs.macrotext,
    "/cleartarget\n/targetexact Pygmy Surf Crawler\n/cleartarget [dead]\n/targetexact Pygmy Surf Crawler",
    "...with the name in every line")
eq(b._attrs.macrotext2, "/cleartarget\n/targetexact Pygmy Surf Crawler\n/tm 8", "right-click unchanged")
eq(T.aim("Pygmy Surf Crawler", 3106, "8"), true, "no variant")
eq(b._attrs.macrotext, "/cleartarget\n/targetexact Pygmy Surf Crawler", "...is the default macro")

-- #95's tagged procedure: what it scores, and what it leaves inconclusive.
do
    local TG = T.state.tagged
    local A = TG.api
    rawset(_G, "UnitIsTapDenied", function(t) local u = WoW.units[t] return u and u.tapped == true end)
    local GA, GB, GC = "Creature-0-1-2-3-3258-0000000A", "Creature-0-1-2-3-3258-0000000B",
        "Creature-0-1-2-3-3258-0000000C"
    local function plate(token, g, extra)
        local u = { name = "Bristleback Quilboar", guid = g, plate = true }
        for k, v in pairs(extra or {}) do u[k] = v end
        WoW.SetUnit(token, u)
    end
    local function target(g) WoW.SetUnit("target", g and { name = "Bristleback Quilboar", guid = g } or nil) end
    local function clickOn(down) b._scripts.PostClick(b, "LeftButton", down) end
    T.state.tagMob = { name = "Bristleback Quilboar", id = 3258 }
    WoW.units = {}
    plate("nameplate1", GA)
    plate("nameplate2", GB)

    -- 1: the tap read, logged with every plate of the name.
    target(GB)
    WoW.units.nameplate2.tapped, WoW.units.target.tapped = true, true
    local ok, _, tap = A.readTap("a mob someone else tagged")()
    check(ok and tap == "true", "the tap read: true on a tagged mob")
    check(logged("nameplate2 0000000B tapped true"), "...with every plate of the name logged")
    WoW.units.nameplate2.tapped = nil

    -- 2: Set aims at a live plate that isn't the target; refused in combat.
    target(nil)
    WoW.combat = true
    check(not pcall(A.setOn, "P1"), "Set is refused in combat")
    WoW.combat = false
    target(GA)
    A.setOn("P1")
    eq(b._attrs.macrotext, "/cleartarget\n/target nameplate2", "Set never aims at your target")
    target(nil)
    plate("nameplate1", GA, { tapped = true })
    A.setOn("P1", false)
    eq(b._attrs.macrotext, "/cleartarget\n/target nameplate2", "...and, for the tag trial, only at an untagged one")
    plate("nameplate1", GA)
    check((A.setOn("P1")), "Set aims the button")
    eq(b._attrs.macrotext, "/cleartarget\n/target nameplate1", "...at one plate (P1)")
    -- Only the action's edge counts: down at ActionButtonUseKeyDown 1, up at 0.
    WoW.useKeyDown = true
    target(GA)
    clickOn(false)
    eq((A.plateTrial("P1")()), false, "the up edge at 1 isn't the click")
    clickOn(true)
    local done, variant, result = A.plateTrial("P1")()
    check(done and result == "targeted the plate's mob", "the down edge at 1 is: scored, " .. tostring(result))
    eq(A.chosen(), "P1", "...and P1 is the macro carried forward")
    -- A hit on a tagged mob is reported, never carried forward.
    TG.passed = nil
    target(nil)
    plate("nameplate1", GA, { tapped = true })
    plate("nameplate2", GB, { tapped = true })
    A.setOn("P1", nil, "2")
    target(GA)
    clickOn(true)
    local dT, _, rT = A.plateTrial("P1")()
    check(dT and rT == "targeted the plate's mob", "a tagged mob's plate targeted: reported")
    eq(A.chosen(), nil, "...but not carried forward to 3")
    plate("nameplate1", GA)
    plate("nameplate2", GB)
    target(nil)
    A.setOn("P1", false)
    target(GA)
    clickOn(true)
    A.plateTrial("P1")()
    eq(A.chosen(), "P1", "an untagged one is")
    -- Back and Set again: the new result replaces the old one.
    target(nil)
    A.setOn("P1", false)
    eq(A.chosen(), nil, "a new Set for P1 drops its earlier result")
    target(nil)
    clickOn(true)
    A.plateTrial("P1")()
    eq(A.chosen(), nil, "...and a miss leaves it dropped")
    A.setOn("P1", false)
    target(GA)
    clickOn(true)
    A.plateTrial("P1")()
    -- The wait's leave: a pass stands only if that visit scored it.
    A.keepPass("P1")()
    eq(A.chosen(), "P1", "left after a scored click: the pass stands")
    A.keepPass("P1")()
    eq(A.chosen(), nil, "left again by Done by hand (after a Back): the pass goes")
    A.setOn("P1", false)
    target(GA)
    clickOn(true)
    A.plateTrial("P1")()
    -- Anything re-aiming the button (/fp so button) ends the trial, and its
    -- clicks aren't logged under it.
    target(nil)
    A.setOn("P1", false)
    T.aim("Bristleback Quilboar", 3258, "8")
    target(GA)
    local before = TG.clicks
    clickOn(true)
    eq(TG.clicks, before, "a click of another macro isn't recorded for the trial")
    check(not (A.plateTrial("P1")()), "the button re-aimed by something else: P1's wait scores nothing")
    -- With only tagged mobs about, the general trial still runs ("prefer").
    plate("nameplate1", GA, { tapped = true })
    plate("nameplate2", GB, { tapped = true })
    target(nil)
    check((A.setOn("P1", "prefer")), "only tagged mobs: Set still aims (the general trial)")
    plate("nameplate1", GA)
    plate("nameplate2", GB)
    -- A target that can't be read could be the mob picked: Set refuses.
    WoW.units.target = { name = "Bristleback Quilboar", guid = WoW.SECRET }
    check(not pcall(A.setOn, "P1", false), "an unreadable target: Set refuses (it could be the picked mob)")
    target(nil)
    A.setOn("P1", false)
    target(GA)
    clickOn(true)
    A.plateTrial("P1")()
    eq(A.chosen(), "P1", "P1 passed again, for what follows")
    -- A wait scores only a click of its own Set: P2's Set skipped, a click
    -- on the P1 button isn't P2's.
    local p2set = A.setStep("P2", "2", "", false)
    p2set.leave("skipped")
    clickOn(true)
    local dS, whyS = A.plateTrial("P2")()
    check(not dS and tostring(whyS):find("Set P2 first", 1, true), "P2's Set skipped: its wait scores nothing")
    A.setOn("P1", false)
    clickOn(true)
    check(not (A.plateTrial("P2")()), "...nor a click of P1's Set")
    eq(TG.passed.P2, nil, "...so P2 isn't credited")
    target(nil)
    A.setOn("P2")
    eq(b._attrs.macrotext, "/cleartarget\n/target [@nameplate1,exists,nodead]", "P2's macro")
    WoW.useKeyDown = false
    target(nil)
    clickOn(true)
    eq((A.plateTrial("P2")()), false, "the down edge at 0 isn't the click")
    WoW.units.target = { name = "Bristleback Quilboar", guid = WoW.SECRET }
    clickOn(false)
    local d2, why2 = A.plateTrial("P2")()
    check(not d2 and tostring(why2):find("inconclusive", 1, true), "a secret target GUID: inconclusive, " .. tostring(why2))
    plate("nameplate1", GA, { dead = true })
    target(nil)
    clickOn(false)
    d2, why2 = A.plateTrial("P2")()
    check(not d2 and tostring(why2):find("dead", 1, true), "the aimed mob dead at the click: a retry, " .. tostring(why2))
    WoW.useKeyDown = true
    plate("nameplate1", GA)

    -- 3a: only a tag the probe saw on the Set-time mob counts.
    target(nil)
    A.setOn("P1", false, "3a")
    eq((A.tagWait()), false, "waiting for the tag")
    plate("nameplate1", GC, { tapped = true })   -- the plate now shows another, tagged mob
    eq((A.tagWait()), false, "a token switching to a tagged mob isn't the change")
    plate("nameplate1", GA, { tapped = true })
    check((A.tagWait()), "the aimed mob tagged: seen")
    target(GA)
    clickOn(true)
    local _, scored, res = A.tagClick()
    check(scored == "scored" and res == "targeted the tagged mob", "...a click then is scored: " .. tostring(res))
    plate("nameplate1", GA)
    target(nil)
    A.setOn("P1", false, "3a")
    plate("nameplate1", GA, { tapped = true })
    A.tagWait()
    WoW.units.target = { name = "Bristleback Quilboar", guid = WoW.SECRET }
    clickOn(true)
    local _, rU = A.tagClick()
    eq(rU, "inconclusive: the target can't be read", "a target that can't be read: inconclusive, not scored")
    plate("nameplate1", GA)
    target(nil)
    A.setOn("P1", false, "3a")
    clickOn(true)   -- the wait finished by hand (Done): no tag seen
    local _, r3a = A.tagClick()
    eq(r3a, "no observed tag, inconclusive", "Done by hand on the tag wait: no observed tag")
    -- Back from the click to the tag wait, then Done by hand: the earlier
    -- sighting doesn't stand.
    target(nil)
    A.setOn("P1", false, "3a")
    plate("nameplate1", GA, { tapped = true })
    A.tagWait()
    check(TG.tagSeen, "a tag seen")
    A.forgetTag("back")   -- the click step's leave, on Back
    clickOn(true)
    local _, rB = A.tagClick()
    eq(rB, "no observed tag, inconclusive", "Back from the click step, then Done by hand: the sighting doesn't stand")
    plate("nameplate1", GA)
    -- Back to 3a's Set and Skip it: the earlier 3a aim is dropped.
    A.setOn("P1", false, "3a")
    A.setStep("chosen", "3a", "", false).leave("skipped")
    local tw, twWhy = A.tagWait()
    check(not tw and tostring(twWhy):find("Set first", 1, true), "a skipped Set drops the earlier aim: its wait waits")

    -- 3b: the plate lost and the click in one uninterrupted lockdown.
    local function fight(on)
        WoW.combat = on
        WoW.fire(on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
    end
    local function lose(token) WoW.units[token] = nil WoW.fire("NAME_PLATE_UNIT_REMOVED", token) end
    A.setOn("P1", nil, "3b")
    eq((A.lostWait()), false, "waiting for the fight")
    fight(true)
    lose("nameplate1")
    target(nil)
    clickOn(true)
    local d3, plateWas, got = A.lostWait()
    check(d3 and plateWas == "absent" and got == "no target", "lost in a fight, clicked in it: scored, " ..
        tostring(plateWas) .. " / " .. tostring(got))
    fight(false)
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    fight(true)
    lose("nameplate1")
    fight(false)
    fight(true)
    clickOn(true)
    eq((A.lostWait()), false, "lost, the fight over, a new one, then the click: inconclusive")
    fight(false)
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    fight(true)
    lose("nameplate1")
    plate("nameplate1", GA)   -- the same mob back on that plate
    clickOn(true)
    local d4, why4 = A.lostWait()
    check(not d4 and tostring(why4):find("lose the plate first", 1, true),
        "the same mob back before the click: not scored, a retry (" .. tostring(why4) .. ")")
    -- Back at the click but gone again before the poll: judged at the click.
    lose("nameplate1")
    plate("nameplate1", GA)
    clickOn(true)
    WoW.units.nameplate1 = nil   -- gone again, no event yet
    local d4b, why4b = A.lostWait()
    check(not d4b and tostring(why4b):find("lose the plate first", 1, true),
        "the original on the plate at the click: not scored, a retry")
    fight(false)
    -- Lost before the fight, the plate reused: the first click in the fight
    -- is inconclusive, and a second one isn't scored either (no loss in it).
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    lose("nameplate1")
    plate("nameplate1", GC)
    fight(true)
    clickOn(true)
    eq((A.lostWait()), false, "lost before the fight: the first click in it is inconclusive")
    A.lostWait()
    clickOn(true)
    eq((A.lostWait()), false, "...and a second click isn't scored: nothing was lost in this fight")
    fight(false)
    -- The plate's mob changed with no REMOVED before the fight: that change
    -- belongs to its own (no) lockdown, never to the fight's.
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    plate("nameplate1", GC)
    A.lostWait()   -- the poll sees the change, out of combat
    fight(true)
    target(nil)
    clickOn(true)
    eq((A.lostWait()), false, "a change seen before the fight: the click in it is inconclusive")
    clickOn(true)
    eq((A.lostWait()), false, "...and stays so: the aimed mob was never seen in this fight")
    fight(false)
    -- PLAYER_REGEN_DISABLED before lockdown reads on: no sighting then, so a
    -- change before lockdown isn't an in-fight loss.
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    WoW.fire("PLAYER_REGEN_DISABLED")   -- lockdown not on yet
    plate("nameplate1", GC)             -- changed before lockdown, no poll in between
    WoW.combat = true
    target(nil)
    clickOn(true)
    eq((A.lostWait()), false, "a change before lockdown read on: not scored")
    fight(false)
    -- An earlier loss retired when the mob is seen back, so a real one counts.
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    lose("nameplate1")                  -- before the fight
    plate("nameplate1", GA)
    fight(true)
    A.lostWait()                        -- seen back, in lockdown
    lose("nameplate1")
    target(nil)
    clickOn(true)
    local dR, plR = A.lostWait()
    check(dR and plR == "absent", "a loss before the fight, the mob back, a real loss in it: scored")
    fight(false)
    -- Judged by the click's own edge: a sighting after the click doesn't make
    -- a pre-lockdown replacement count...
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    plate("nameplate1", GC)             -- replaced before the fight
    fight(true)
    target(nil)
    clickOn(true)
    plate("nameplate1", GA)             -- A back, then gone, before the poll
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    lose("nameplate1")
    local dO, wO = A.lostWait()
    check(not dO and tostring(wO):find("not one fight", 1, true), "a sighting after the click doesn't qualify it")
    -- ...and rejecting that click keeps the newer loss: a click now counts.
    clickOn(true)
    local dO2, pO2 = A.lostWait()
    check(dO2 and pO2 == "absent", "the newer loss stands: the next click is scored")
    fight(false)
    -- Seen in the fight, then gone with no REMOVED: the click's own read is
    -- enough to establish the loss.
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    fight(true)
    A.lostWait()                        -- seen, in lockdown
    WoW.units.nameplate1 = nil          -- gone, no event
    target(nil)
    clickOn(true)
    local dA, pA = A.lostWait()
    check(dA and pA == "absent", "gone with no REMOVED after a sighting in the fight: scored")
    fight(false)
    -- ...and a valid loss stays valid when A comes back before the poll.
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    fight(true)
    lose("nameplate1")
    target(nil)
    clickOn(true)
    plate("nameplate1", GA)             -- back before the poll
    local dV, plV = A.lostWait()
    check(dV and plV == "absent", "a valid loss and click, the mob back before the poll: still scored")
    fight(false)
    -- No combat events: 3b can't tell fights apart.
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    TG.combatOk = false
    local dN, wN = A.lostWait()
    check(dN and tostring(wN):find("inconclusive", 1, true), "combat events refused: 3b inconclusive")
    TG.combatOk = true
    -- A plate that can't be read at the click: inconclusive, not "another mob".
    plate("nameplate1", GA)
    A.setOn("P1", nil, "3b")
    fight(true)
    lose("nameplate1")
    plate("nameplate1", WoW.SECRET)
    target(nil)
    clickOn(true)
    local dU, whyU = A.lostWait()
    check(not dU and tostring(whyU):find("can't be read", 1, true), "an unreadable plate at the click: inconclusive")
    fight(false)

    -- 4: a REMOVED forgets the plate's GUID; only a change with none counts.
    plate("nameplate1", GA)
    plate("nameplate2", GB)
    TG.set = nil
    A.stability()
    TG.stabPoll()
    lose("nameplate2")
    TG.stabPoll()
    plate("nameplate2", GC)   -- no ADDED seen: the REMOVED alone says it's a new one
    TG.stabPoll()
    eq(TG.stab.silent, 0, "a plate removed, then another mob on it: not a silent change")
    plate("nameplate1", GC)
    TG.stabPoll()
    eq(TG.stab.silent, 1, "a plate's mob changing with no REMOVED: counted")
    -- Right after ADDED: what it showed then is the baseline.
    lose("nameplate3")
    plate("nameplate3", GA)
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    plate("nameplate3", GB)
    TG.stabPoll()
    eq(TG.stab.silent, 2, "a change right after ADDED, before any poll: counted")
    -- An ADDED on a token still holding another mob, no REMOVED between.
    plate("nameplate3", GC)
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    eq(TG.stab.silent, 3, "ADDED showing another mob than the token held: counted")
    -- A refused subscription: the counts mean nothing.
    TG.stab.from = -1000
    TG.combatOk = false
    local dC, wC = A.stability()
    check(dC and tostring(wC):find("combat events", 1, true),
        "a combat event refused: 4 can't know it was out of combat, inconclusive")
    TG.combatOk, TG.plateOk = true, false
    local dL, wL = A.stability()
    check(dL and tostring(wL):find("inconclusive", 1, true), "a plate event not registered: inconclusive")
    TG.plateOk = true
    -- In combat the two minutes start again once out of it.
    WoW.combat = true
    local dF, wF = A.stability()
    check(not dF and tostring(wF):find("leave combat", 1, true), "in combat: no result, it waits")
    eq(TG.stab, nil, "...and the window restarts")
    WoW.combat = false
    -- A whole fight between two polls restarts it too.
    plate("nameplate1", GA)
    A.stability()
    check(TG.stab ~= nil, "a window running")
    fight(true)
    fight(false)
    eq(TG.stab, nil, "a fight between polls restarts the window")
    -- Nothing seen twice: inconclusive, not "no changes".
    WoW.units.nameplate1, WoW.units.nameplate2, WoW.units.nameplate3 = nil, nil, nil
    A.stability()
    TG.stabPoll()
    TG.stab.from = -1000
    local dE, wE = A.stability()
    check(dE and tostring(wE):find("inconclusive", 1, true), "no plate to compare: inconclusive, " .. tostring(wE))
    A.stopStability()
    WoW.units.nameplate3 = nil
    -- The start takes its own snapshot: a swap before the first poll counts
    -- (Codex on PR #101).
    plate("nameplate1", GA)
    A.stability()
    plate("nameplate1", GB)
    TG.stabPoll()
    eq(TG.stab.silent, 1, "a swap before the first poll: compared with the start's snapshot")
    A.stopStability()
    WoW.units.nameplate1 = nil

    -- 5: needs ranges (Stakeout's seam); without them it says so and ends,
    -- even with no plate in view (moving wouldn't help).
    WoW.units.nameplate1, WoW.units.nameplate2 = nil, nil
    TG.set, TG.near = nil, nil
    local d5, why5 = A.nearestTrial()
    check(d5 and tostring(why5):find("range unavailable", 1, true), "no range without Stakeout: inconclusive, done")
    plate("nameplate1", GA)
    plate("nameplate2", GB)
    local ranges = { nameplate1 = { 0, 10 }, nameplate2 = { 25, 30 } }
    rawset(_G, "Stakeout", { _test = { range = { Get = function(u)
        local r = ranges[u]
        if r then return r[1], r[2] end
    end } } })
    -- Its Set skipped: the button keeps an older macro, so nothing scores.
    A.setOn("P1", false)
    A.setNearest()
    A.dropSet("skipped")
    local dK, whyK = A.nearestTrial()
    check(not dK and tostring(whyK):find("Set first", 1, true), "5's Set skipped: its wait scores nothing")
    A.setNearest()
    -- A click on a pair lost before the poll isn't the replacement's.
    A.nearestTrial()   -- picks the pair
    target(GA)
    clickOn(true)
    WoW.units.nameplate2 = nil
    plate("nameplate3", GB)
    ranges.nameplate3 = { 25, 30 }
    A.nearestTrial()
    eq(#TG.near.scored, 0, "a click on the old pair isn't scored for the new one")
    WoW.units.nameplate3, ranges.nameplate3 = nil, nil
    plate("nameplate2", GB)
    TG.near = nil
    A.nearestTrial()   -- picks the pair
    target(GA)
    clickOn(true)
    -- Scored as the click's edge read them, though they swap before the poll.
    ranges.nameplate1, ranges.nameplate2 = { 25, 30 }, { 0, 10 }
    local d51, w51 = A.nearestTrial()
    check(not d51 and tostring(w51):find("1 of 4", 1, true), "1 of 4 scored, from the click's own reading")
    eq(TG.near.scored[1], "the nearer", "...the nearer at the click, not at the poll")
    ranges.nameplate1, ranges.nameplate2 = { 25, 30 }, { 0, 10 }
    target(nil)
    clickOn(true)
    local _, noT = A.nearestTrial()
    check(tostring(noT):find("no target", 1, true), "a click with no target: said so, not \"a third mob\"")
    ranges.nameplate1, ranges.nameplate2 = { 0, 10 }, { 25, 30 }
    target(GA)
    clickOn(true)
    local _, same = A.nearestTrial()
    check(tostring(same):find("other one is nearer", 1, true), "the same nearer one again: not scored")
    ranges.nameplate1, ranges.nameplate2 = { 25, 30 }, { 0, 10 }
    target(GB)
    clickOn(true)
    A.nearestTrial()
    ranges.nameplate1, ranges.nameplate2 = { 0, 10 }, { 25, 30 }
    target(GA)
    clickOn(true)
    A.nearestTrial()
    clickOn(true)                       -- the same nearer one again: not scored...
    ranges.nameplate1, ranges.nameplate2 = { 25, 30 }, { 0, 10 }
    target(GB)
    clickOn(true)                       -- ...then the valid fourth, both before one poll
    WoW.units.nameplate2 = nil          -- a plate goes before the poll: the clicks still count
    clickOn(true)                       -- ...and a click after it doesn't hide them
    local d6, picks = A.nearestTrial()
    check(d6 and picks == "the nearer, the nearer, the nearer, the nearer", "four alternating clicks: " .. tostring(picks))
    lose("nameplate2")
    A.nearestTrial()
    eq(TG.near.pair, nil, "...a lost pair is dropped, to be chosen again")
    -- A pair member moved to another plate isn't the same observation.
    plate("nameplate2", GB)
    TG.near = nil
    A.nearestTrial()
    WoW.units.nameplate2 = nil
    plate("nameplate3", GB)
    A.nearestTrial()
    check(TG.near.pair == nil or TG.near.pair[2].token ~= "nameplate2", "a mob moved to another plate: the pair is chosen again")
    -- A pair member dead on its plate is let go for a live one.
    WoW.units.nameplate3 = nil
    plate("nameplate2", GB)
    TG.near = nil
    A.nearestTrial()
    plate("nameplate2", GB, { dead = true })
    plate("nameplate3", GC)
    ranges.nameplate1, ranges.nameplate3 = { 0, 10 }, { 50, 60 }
    A.nearestTrial()
    check(TG.near.pair and TG.near.pair[2].guid == GC, "a dead pair member: the pair is chosen again with a live one")
    WoW.units.nameplate3, ranges.nameplate3 = nil, nil
    -- A third mob picked: an outcome kept in the result, with its range and
    -- the count of other live ones (Codex on PR #101).
    plate("nameplate2", GB)
    plate("nameplate3", GC)
    ranges.nameplate1, ranges.nameplate2, ranges.nameplate3 = { 0, 10 }, { 25, 30 }, { 40, 45 }
    TG.near = nil
    A.nearestTrial()
    check(TG.near.pair and TG.near.pair[1].guid == GA and TG.near.pair[2].guid == GB, "the pair: the first two apart")
    target(GC)
    ranges.target = { 40, 45 }
    clickOn(true)
    local n3 = #db.log
    A.nearestTrial()
    local s1 = tostring(TG.near.scored[1])
    check(s1:find("a third mob", 1, true) and s1:find("40-45 yd", 1, true), "a third mob picked: scored as one, at its range: " .. s1)
    local logged = false
    for i = n3 + 1, #db.log do if db.log[i]:find("1 other live", 1, true) then logged = true end end
    check(logged, "...and the log counts the other live one")
    ranges.target = nil
    for _, step in ipairs({ { { 25, 30 }, { 0, 10 }, GB }, { { 0, 10 }, { 25, 30 }, GA }, { { 25, 30 }, { 0, 10 }, GB } }) do
        ranges.nameplate1, ranges.nameplate2 = step[1], step[2]
        target(step[3])
        clickOn(true)
    end
    local dT, wT = A.nearestTrial()
    check(dT and tostring(wT):find("a third mob was picked", 1, true), "...and the result says the pair isn't the rule: " .. tostring(wT))
    WoW.units.nameplate3, ranges.nameplate3 = nil, nil
    rawset(_G, "Stakeout", nil)
    -- Stopped mid-trial: the aim goes, and nothing more is logged for it.
    plate("nameplate1", GA)
    plate("nameplate2", GB)
    target(nil)
    A.setOn("P1", false)
    A.keepPass("P1")("stopped")
    eq(TG.set, nil, "a stopped trial drops its aim")
    local n0 = #db.log
    lose("nameplate1")
    local quiet = true
    for i = n0 + 1, #db.log do if db.log[i]:find("tagged:", 1, true) then quiet = false end end
    check(quiet, "...so a later event on that plate isn't logged for it")
    A.setOn("P1", false)
    A.stopAim("stopped")
    eq(TG.set, nil, "the other aimed waits drop it on Stop too")
    plate("nameplate1", GA)

    -- The first step starts a fresh run; with no target it stays (a throw).
    WoW.units.target = nil
    check(not pcall(A.readMob), "Read target with no target throws: the step stays")
    eq(T.state.tagMob, nil, "...and the last run's mob doesn't carry on")
    -- UnitName throwing: never the error's text as the mob's name.
    target(GA)
    local realName = rawget(_G, "UnitName")
    rawset(_G, "UnitName", function() error("UnitName broke") end)
    check(not pcall(A.readMob), "UnitName throwing: Read target throws too")
    eq(T.state.tagMob, nil, "...and no mob is set")
    rawset(_G, "UnitName", realName)
    -- The first step skipped: nothing of the last run carries on.
    T.state.tagMob = { name = "Bristleback Quilboar", id = 3258 }
    A.resetRun()
    eq(T.state.tagMob, nil, "a fresh run with its Read skipped has no mob")
    T.state.tagMob = { name = "Bristleback Quilboar", id = 3258 }

    -- The cleanup: refused in combat (the step stays), done out of it.
    T.aim("Bristleback Quilboar", 3258, "8")
    WoW.combat = true
    check(not pcall(A.cleanup), "Remove in combat throws: the step stays")
    check(b._shown, "...and the button is still up")
    WoW.combat = false
    check(A.cleanup(), "out of combat it's removed")
    eq(b._shown, false, "...hidden")
    rawset(_G, "UnitIsTapDenied", nil)
    WoW.units = {}
end

-- #98's customize procedure: the distance wait needs two numbers on a button.
do
    local Cz = ns._test.customize
    local fb = CreateFrame("Button", "StakeoutBtn1", UIParent)
    fb.npcName = "Bristleback Quilboar"
    fb.dist = fb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fb.dist:SetText("30")
    fb.dist:Show()
    Cz.forgetDistances()
    check(not Cz.distanceChanges(), "one distance read: still waiting")
    fb.dist:SetText("25")
    check((Cz.distanceChanges()), "a second, different one: done")
    -- A second run starts from nothing: one reading isn't enough again.
    Cz.forgetDistances()
    check(not Cz.distanceChanges(), "a new attempt: one reading, still waiting")
    -- A layout switch ("25" on an icon, "25 yd" in a list) isn't a move.
    fb.dist:SetText("25 yd")
    check(not Cz.distanceChanges(), "\"25\" then \"25 yd\": one reading, not a change")
    fb:Hide()
    -- Where the panel is: visible, inside the screen, anchored as its branch says.
    local uw, uh = UIParent._width, UIParent._height
    UIParent:SetSize(1920, 1080)
    local fcfg = CreateFrame("Frame", "StakeoutConfigFrame", UIParent)
    local fpan = CreateFrame("Frame", "StakeoutCustomizeFrame", fcfg)
    fpan:SetPoint("TOPLEFT", fcfg, "TOPRIGHT", 4, 0)
    fpan.where, fpan._left, fpan._right = "right", 900, 1256
    check((Cz.where()()), "beside the settings, anchored as placed: a pass")
    check(not Cz.where("left")(), "...but not when the step wants it on the left")
    fpan.where = "left"
    check(not Cz.where("left")(), "a branch its anchor doesn't match: a fail")
    fpan.where = "right"
    fpan._right = 2000
    check(not Cz.where()(), "past the screen's edge: a fail")
    fpan._right = 1256
    -- The drag step's expectation: left where the pair fits, over where not.
    eq(Cz.leftOrOver(1920, 712, 356), "left", "a wide screen: on the left")
    eq(Cz.leftOrOver(1024, 712, 356), "over", "a 1024-wide screen: over the left column")
    fcfg:SetSize(712, 600)
    fpan:SetSize(356, 600)
    fpan:ClearAllPoints()
    fpan:SetPoint("TOPLEFT", fcfg, "TOPLEFT", 0, 0)
    fpan.where, fpan._left, fpan._right = "over", 0, 356
    -- One callback, as the registered step has, run at both widths in turn.
    local dragCheck = Cz.where(Cz.leftOrOver)
    UIParent:SetSize(1024, 768)
    check((dragCheck()), "the drag step on a narrow screen: over is a pass")
    UIParent:SetSize(1920, 1080)
    check(not dragCheck(), "...the same step on a wide one: over is a fail (it should be left)")
    UIParent:SetSize(1024, 768)
    check((dragCheck()), "...and narrow again: a pass again (worked out each run)")
    UIParent:SetSize(1920, 1080)
    fcfg:Hide()
    check(not pcall(Cz.where()), "the settings closed (the panel not visible): it says to open them")
    UIParent._width, UIParent._height = uw, uh
end

-- The list layout mockups (#88): plain frames, never secure.
do
    local H = T.hud
    eq(H.shortProgress({ "Big Game: 3/10 Stranglethorn Tiger slain" }), "3/10", "progress: the count")
    eq(H.shortProgress({ "Welcome: ready to turn in" }), "turn in", "...or the turn-in")
    local layout, look, n = H.show("compact", "forever", false)
    eq(layout .. " " .. look .. " " .. n, "compact forever 0", "nothing on Stakeout's frame: no rows")
    layout, look, n = H.show("wide", "forever", true)
    eq(n, 11, "the demo's eleven rows")
    local f = H.frame()
    check(f:IsShown() and not f._template:find("Secure", 1, true), "a plain frame, shown")
    local tiger = H.rows()["Stranglethorn Tiger"]
    eq(tiger.progress:GetText(), "4/10", "a row's progress")
    eq(H.rows()["Jungle Stalker"].progress:GetText(), "1/10", "a hunted row keeps its progress")
    H.show("compact", "glass", true)
    check(H.rows()["Stranglethorn Tiger"] ~= tiger, "a new look: new rows")
    H.hide()
    eq(f:IsShown(), false, "hidden")
    SlashCmdList.FOREVERPROBE("so hud wide")
    eq(f:IsShown(), true, "/fp so hud wide shows it")
    SlashCmdList.FOREVERPROBE("so hud off")
    eq(f:IsShown(), false, "/fp so hud off hides it")
    -- No row or group header overlaps another, in either layout (Codex: a
    -- full line at a group's end was overlapped by the next header).
    local function overlaps(layout)
        H.show(layout, "forever", true)
        local fr, boxes = H.frame(), {}
        local rowH = layout == "wide" and 34 or 22
        for _, row in pairs(H.rows()) do
            if row:IsShown() then
                local p = row._points[#row._points]
                boxes[#boxes + 1] = { x = p[4], top = -p[5], bottom = -p[5] + rowH }
            end
        end
        for _, h in ipairs(fr.headers) do
            if h:IsShown() then
                local p = h._points[#h._points]
                boxes[#boxes + 1] = { x = nil, top = -p[5], bottom = -p[5] + 12 }
            end
        end
        local bad = 0
        for i = 1, #boxes do
            for j = i + 1, #boxes do
                local a, c = boxes[i], boxes[j]
                local sameColumn = a.x == nil or c.x == nil or a.x == c.x
                if sameColumn and a.top < c.bottom and c.top < a.bottom then bad = bad + 1 end
            end
        end
        return bad, #boxes
    end
    local bad, boxes = overlaps("compact")
    eq(bad, 0, "compact: nothing overlaps (" .. boxes .. " rows and headers)")
    bad, boxes = overlaps("wide")
    eq(bad, 0, "wide: nothing overlaps, a full line before a new group included (" .. boxes .. ")")

    -- Glass, then Forever again: a frame per look, so no glass is left on Forever's.
    H.show("compact", "glass", true)
    local glassFrame = H.frame()
    H.show("compact", "forever", true)
    check(H.frame() ~= glassFrame and H.frame():IsShown() and not glassFrame:IsShown(),
        "back to Forever: its own frame, the glass one hidden")
    H.show("compact", "glass", true)
    eq(H.frame(), glassFrame, "...and Glass again reuses the glass one")
    -- Forever -> Glass -> Forever: each frame stands against UIParent, never
    -- against the other look's frame (Codex on #91: a circular anchor).
    H.show("compact", "forever", true)
    local foreverFrame = H.frame()
    local function anchoredTo(f, other)
        for _, p in ipairs(f._points or {}) do if p[2] == other then return true end end
        return false
    end
    check(not anchoredTo(foreverFrame, glassFrame) and not anchoredTo(glassFrame, foreverFrame),
        "a look round trip leaves neither frame anchored to the other")
    H.hide()

    -- A rejected Read face throws, so the procedure stays on that step; the
    -- command form just returns the reason (Codex on #91).
    WoW.units = {}
    local okStep, whyStep = pcall(H.startFaceStep)
    check(not okStep and tostring(whyStep):find("no target", 1, true), "a rejected read keeps the step: " .. tostring(whyStep))
    eq(H.faceDrawn(), false, "...and nothing counts as drawn")

    -- Stakeout still showing a face the mockup missed: a boolean from either
    -- representation (#90's btn.portrait, or main's btn.portraitOf).
    WoW.allowGlobal("StakeoutBtn1")
    WoW.allowGlobal("StakeoutBtn2")
    local b1 = CreateFrame("Button", "StakeoutBtn1", UIParent)
    b1.npcName, b1.portrait = "Face Kept", {}
    b1.label = b1:CreateFontString()
    b1.icon = b1:CreateTexture()
    local b2 = CreateFrame("Button", "StakeoutBtn2", UIParent)
    b2.npcName, b2.portraitOf = "Old Face", "Old Face"
    b2.label = b2:CreateFontString()
    b2.icon = b2:CreateTexture()
    _G.StakeoutBtn1, _G.StakeoutBtn2 = b1, b2
    local rows = H.stakeoutRows()
    eq(rows[1] and rows[1].stakeoutFace, true, "#90's cache: true")
    eq(rows[2] and rows[2].stakeoutFace, true, "main's portraitOf: true")
    b2.portraitOf = "Someone Else"
    eq(H.stakeoutRows()[2].stakeoutFace, false, "a face of another name: false, never a texture")
    _G.StakeoutBtn1, _G.StakeoutBtn2 = nil, nil

    local ok, why = H.startFace()
    eq(ok, false, "the face test needs a target: " .. tostring(why))
    eq(H.pollFace(), false, "...and polls nothing before Read face")

    -- Through ForeverProbe's runner: a face that is never drawn (the display
    -- ID stays 0, run #497) ends the wait by timeout or by Done, and neither
    -- can give a yes/no match: the comparison is a note step whose check
    -- FAILs without a draw (Codex on #91).
    local S = FP.Steps
    local take, nowFn = FP.Screenshots.Take, S.Now
    FP.Screenshots.Take = function(_, _, cb) if cb then cb(nil) end end
    local function faceRun(endWait)
        WoW.SetUnit("target", { name = "Kurzen Jungle Fighter", guid = "Creature-0-0-0-0-937-1" })
        fp("steps so face")
        local rec = FP.db.steps.records["StakeoutProbe/face"]
        S.Run()
        eq(rec.at, 2, "Read face on a living target moves on to the wait")
        endWait()
        eq(rec.at, 3, "the wait ended")
        S.Next()
        local r = rec.results[3]
        check(r.status ~= "yes" and r.status ~= "no", "no match answer is possible: " .. tostring(r.status))
        eq(r.check, "FAIL", "the comparison's check fails without a draw")
        fp("steps stop")
        return rec
    end
    local rec = faceRun(function()
        local t0 = S.Now()
        S.Now = function() return t0 + 16 end
        S.Poll()
        S.Now = nowFn
    end)
    eq(rec.results[2].status, "timeout", "the first run timed out")
    rec = faceRun(function() S.DoneByHand() end)
    eq(rec.results[2].check, "FAIL", "Done by hand without a draw: the wait's check fails")
    FP.Screenshots.Take = take
    WoW.units = {}
end

local errors = 0
for _, l in ipairs(db.log) do if l:find("ERROR") then errors = errors + 1 end end
eq(errors, 0, "nothing threw")
eq(#WoW.chat, 0, "nothing in chat")

done("test_probe")
