-- StakeoutProbe: a ForeverProbe module (the host loaded from its checkout).
-- Its commands run on the stubbed client and log what they read, never to
-- chat; its procedures are defined and start. A fake LibQuestieDB stands in
-- for QuestieDB (another addon's global, not a client API). Runs locally only:
-- CI sets FOREVERPROBE_OPTIONAL=1 and this file skips itself.
dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local check, eq = H.check, H.eq

-- ForeverProbe, as the client loads it before a dependent (GUIDE.md, section 8).
local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
local toc = io.open(root .. "/ForeverProbe.toc", "rb")
if not toc then
    if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
        print("test_probe: SKIPPED (ForeverProbe is private and local; the probe tests run locally)")
        os.exit(0)
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
function debugprofilestop() return WoW.time * 1000 end

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
check(b and b.template == "SecureActionButtonTemplate", "a secure button")
eq(b.attrs.macrotext, "/cleartarget\n/targetexact Orgnil Soulscar", "left: target by exact name")
eq(b.attrs.macrotext2, "/cleartarget\n/targetexact Orgnil Soulscar\n/tm !8", "right: and mark")
eq(#b.clicks, 2, "both mouse edges registered")
-- A click: the secure macro runs (here: the target set by hand), then PostClick logs what it got.
b.hooks.PostClick(b, "LeftButton", true)
check(logged("click LeftButton down: target <a player> %(wanted"), "a player targeted is logged as one")
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000ABCD", creatureID = 3142,
    friendly = true })
b.hooks.PostClick(b, "RightButton", false)
check(logged("click RightButton up: target Orgnil Soulscar %(wanted Orgnil Soulscar%) plate false mark nil "
    .. "dead false unit 0000ABCD"), "a click logs the target it got, alive or not, and which one")
eq(T.state.clicks, 2, "...and counts")
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000BEEF", creatureID = 3142,
    dead = true })
b.hooks.PostClick(b, "LeftButton", true)
check(logged("dead true unit 0000BEEF"), "a corpse is logged as one")
eq(T.state.lastClick.dead, true, "...and recorded")
WoW.inCombat = true
fp("so button Vile Familiar")
eq(b.attrs.macrotext, "/cleartarget\n/targetexact Orgnil Soulscar", "not changed in combat")
check(logged("button: in combat"), "...saying why")
WoW.inCombat = false
fp("so button off")
eq(b.shown, false, "button off hides it")

--------------------------------------------------------------------------------
-- Procedures
--------------------------------------------------------------------------------

for _, name in ipairs({ "quests", "range", "hostile", "events", "core", "mulgore", "corpse" }) do
    fp("steps so " .. name)
    local rec = FP.db.steps.records["StakeoutProbe/" .. name]
    eq(rec and rec.status, "active", "procedure " .. name .. " starts")
    fp("steps stop")
end

-- The corpse variants set the left-click macro, with the name filled in.
eq(T.aim("Pygmy Surf Crawler", 3106, "8",
    "/cleartarget\n/targetexact <name>\n/cleartarget [dead]\n/targetexact <name>"), true, "a variant is set")
eq(b.attrs.macrotext,
    "/cleartarget\n/targetexact Pygmy Surf Crawler\n/cleartarget [dead]\n/targetexact Pygmy Surf Crawler",
    "...with the name in every line")
eq(b.attrs.macrotext2, "/cleartarget\n/targetexact Pygmy Surf Crawler\n/tm 8", "right-click unchanged")
eq(T.aim("Pygmy Surf Crawler", 3106, "8"), true, "no variant")
eq(b.attrs.macrotext, "/cleartarget\n/targetexact Pygmy Surf Crawler", "...is the default macro")

local errors = 0
for _, l in ipairs(db.log) do if l:find("ERROR") then errors = errors + 1 end end
eq(errors, 0, "nothing threw")
eq(#WoW.messages, 0, "nothing in chat")

H.done("test_probe")
