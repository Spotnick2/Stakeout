------------------------------------------------------------
-- test_questie.lua - QuestieData.lua, QuestieDB as the quest targets' data
-- provider (#24, Phase 3, #68), and the NEAR tier it feeds in Quests.lua.
--
-- The stand-in LibQuestieDB below answers the way contract 4 does (its
-- Types/*.t.lua in References\Addons\QuestsLeveling\QuestieDB\QuestieDB, 1.0.15):
-- entity Get(id, key), ObjectiveFirst sets, Support.Get("ZoneDB").private
-- strings. The numbers come from the probe (FOREVER-PROBE.md, section 12):
-- Durotar is area 14 -> uiMap 1411, 5287 x 3525 yd.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local DB = { Quest = {}, Npc = {}, Item = {}, Object = {} }
local FIRST = { itemObjectiveFirst = {}, killCreditObjectiveFirst = {}, objectObjectiveFirst = {},
                eventObjectiveFirst = {}, spellObjectiveFirst = {} }
local ZONE = {
    areaIdToUiMapId = "return {\n    [14] = 1411, -- Durotar\n    [215] = 1412,\n    [2257] = 2257,\n}",
    areaIdToUiMapIdOverride = "return {\n    [0] = 0, -- fail-safe\n    [2257] = 0,\n}",
}
local reads, contract = 0, true

local function entity(rows)
    return { Get = function(id, key)
        reads = reads + 1
        local row = rows[id]
        if row == "throw" then error("bad row") end
        return row and row[key]
    end }
end

local function questieDB()
    return {
        RequireContract = function(n) return contract and n == 4, (not contract) and "too old" or nil end,
        Quest = entity(DB.Quest), Npc = entity(DB.Npc), Item = entity(DB.Item), Object = entity(DB.Object),
        ObjectiveFirst = FIRST,
        Support = { Get = function(name) if name == "ZoneDB" then return { private = ZONE } end end },
    }
end

local MAP, W, Hh = 1411, 5287, 3525
WoW.mapSizes[MAP] = { W, Hh }
-- The player, `yards` east of a point given in 0..100 on Durotar.
local function stand(x, y, yards)
    WoW.position = { map = MAP, x = x / 100 + (yards or 0) / W, y = y / 100 }
end

------------------------------------------------------------
-- Not loaded, or the wrong contract: no provider
------------------------------------------------------------
do
    WoW.events = {}
    local _, ns = WoW.loadAddon({ savedDB = { questTargets = true } })
    H.eq(ns.questData, nil, "without LibQuestieDB, no provider")
    H.check(not ns.questieData.attached(), "...and nothing attached")
    WoW.messages = {}
    ns.quests.PrintState()
    H.check(WoW.chat():find("Without quest data", 1, true), "the state line says so")
end

do
    contract = false
    rawset(_G, "LibQuestieDB", questieDB())
    WoW.events = {}
    local _, ns = WoW.loadAddon({ savedDB = { questTargets = true } })
    H.eq(ns.questData, nil, "a LibQuestieDB that refuses contract 4 isn't used")
    contract = true
end

------------------------------------------------------------
-- Loaded: the provider's answers
------------------------------------------------------------
rawset(_G, "LibQuestieDB", questieDB())
WoW.events = {}
local T, ns = WoW.loadAddon({ savedDB = { questTargets = true } })
local P = ns.questieData.Provider
local Q = ns.quests
H.eq(ns.questData, P, "with LibQuestieDB at load, the provider is set")
WoW.messages = {}
Q.PrintState()
H.check(WoW.chat():find("With Questie's data", 1, true), "the state line names Questie's data: " .. WoW.chat())

-- Questie's order: creatures, objects, items, kill credits.
DB.Npc[3106] = { name = "Pygmy Surf Crawler" }
DB.Npc[3103] = { name = "Makrura Clacker" }
DB.Npc[9000] = { name = "Root Credit" }
DB.Item[5001] = { name = "Crawler Mucus", npcDrops = { 3106, 3103 } }
DB.Item[5002] = { name = "Intact Makrura Eye", npcDrops = { 3103 } }
DB.Object[700] = { name = "Attack Plan" }
DB.Quest[100] = { objectives = {
    { { 3106 }, { 3103, "Clacker override" } },
    { { 700 } },
    { { 5001 }, { 5002 } },
    { 909, 1 },                                  -- reputation: not a unit
    { { { 9001, 9002 }, 9000, "Credit text" } },
    { { 1234, "spell" } },                       -- spell: not a unit
} }

local function shape(list)
    if not list then return "nil" end
    local out = {}
    for _, e in ipairs(list) do
        out[#out + 1] = e.kind .. ":" .. e.id .. ":" .. tostring(e.name) .. (e.ids and (":" .. table.concat(e.ids, "+")) or "")
    end
    return table.concat(out, ", ")
end

H.eq(shape(P.Objectives(100)),
    "creature:3106:Pygmy Surf Crawler, creature:3103:Clacker override, object:700:Attack Plan, "
    .. "item:5001:Crawler Mucus, item:5002:Intact Makrura Eye, killcredit:9000:Credit text:9001+9002",
    "Questie's order; the entry's text over the stored name; no reputation or spell entries")

FIRST.itemObjectiveFirst[100] = true
H.eq(shape(P.Objectives(100)):match("^[^,]+, [^,]+"), "item:5002:Intact Makrura Eye, item:5001:Crawler Mucus",
    "an item-first quest puts its items in front one at a time, as Questie does (so reversed)")
FIRST.itemObjectiveFirst[100] = nil
FIRST.killCreditObjectiveFirst[100] = true
H.eq(shape(P.Objectives(100)):match("^[^,]+"), "killcredit:9000:Credit text:9001+9002", "kill credit first")
FIRST.killCreditObjectiveFirst[100] = nil

DB.Quest[101] = { objectives = { { { 9000 } }, nil, nil, nil, { { { 9001 }, 9000 } } } }
H.eq(shape(P.Objectives(101)), "creature:9000:Root Credit, killcredit:9000:Root Credit:9001",
    "no text: the NPC's name, for a kill credit its root's")
H.eq(P.Objectives(999), nil, "a quest QuestieDB doesn't know: nil")
DB.Quest[823] = { objectives = {}, finishedBy = { { 3142 } } }
H.eq(shape(P.Objectives(823)), "", "a delivery quest: known, with nothing to do")
DB.Quest[102] = { objectives = { { { 3106 }, "junk" } } }
H.eq(P.Objectives(102), nil, "one malformed entry: the quest is read as unknown")
DB.Quest[103] = "throw"
H.eq(P.Objectives(103), nil, "a read that errors: nil")

H.eq(table.concat(P.FinishedBy(823), ","), "3142", "who ends a quest: its NPCs")
DB.Quest[824] = { finishedBy = { nil, { 55 } } }
H.eq(P.FinishedBy(824), nil, "an object that ends it isn't a unit")
H.eq(table.concat(P.ItemDroppers(5001), ","), "3106,3103", "an item's droppers")
H.eq(P.NpcName(3103), "Makrura Clacker", "an NPC's name")
H.eq(P.NpcName(4), nil, "an unknown NPC's: nil")

------------------------------------------------------------
-- Spawns: area -> uiMap, 0..100 -> 0..1, sentinels out
------------------------------------------------------------
local AM = ns.questieData.ParseAreaMap
H.eq(AM("return {\n [14] = 1411, -- Durotar\n [215] = 1412,\n}")[215], 1412, "the area map parses")
H.eq(AM("return { [1] = 2, os.exit() }"), nil, "anything but [area] = map rejects the whole string")
H.eq(AM("print(1) return { [1] = 2 }"), nil, "...code before the table too")

DB.Npc[3142] = { name = "Orgnil Soulscar", spawns = { [14] = { { 52.0, 43.0 }, { -1, -1 } }, [2257] = { { 5, 5 } } } }
local sp = P.Spawns(3142)
H.check(sp and sp[1411] and #sp[1411] == 1, "spawns land on their uiMap, the -1 sentinel skipped")
H.check(math.abs(sp[1411][1][1] - 0.52) < 1e-9 and math.abs(sp[1411][1][2] - 0.43) < 1e-9, "...in 0..1")
H.eq(sp[2257], nil, "an area the Override maps to 0 is dropped")
DB.Npc[3143] = { name = "Nowhere", spawns = { [99999] = { { 1, 1 } } } }
H.eq(P.Spawns(3143), nil, "an area with no uiMap: no spawns")
reads = 0
P.Spawns(3142)
H.eq(reads, 0, "spawns are cached")

------------------------------------------------------------
-- Turn-in NEAR: 80 yd in, 100 yd out
------------------------------------------------------------
local function order()
    local out = {}
    for _, b in ipairs(T.buttons) do if b.shown then out[#out + 1] = b.npcName end end
    return table.concat(out, ",")
end
local function rebuild()
    WoW.fire("QUEST_LOG_UPDATE")
    WoW.flushTimers()
end

WoW.questLog = { { questID = 823, title = "Report to Orgnil", rows = {}, complete = true } }
stand(52, 43, 70)
rebuild()
H.eq(order(), "Orgnil Soulscar", "a finished quest's NPC, 70 yd from his spawn: a button, with no plate in sight")
local o = T.buttons[1]
H.eq(o:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Orgnil Soulscar", "...that targets him by name")
H.check(o.friendly, "...in the NPC row")

stand(52, 43, 90); Q.Tick()
H.eq(order(), "Orgnil Soulscar", "90 yd: still near (it takes 100 to leave)")
stand(52, 43, 110); Q.Tick()
H.eq(order(), "", "110 yd: gone")
stand(52, 43, 90); Q.Tick()
H.eq(order(), "", "back to 90 yd: not yet (it takes 80 to come)")
stand(52, 43, 60); Q.Tick()
H.eq(order(), "Orgnil Soulscar", "60 yd: back")

WoW.position = { map = 1412, x = 0.52, y = 0.43 }
WoW.mapSizes[1412] = { 6154, 4102 }
Q.Tick()
H.eq(order(), "", "on another map his Durotar spawn is no help")
WoW.position = nil
Q.Tick()
H.eq(order(), "", "nor with no position (an instance)")

stand(52, 43, 10)
WoW.questLog[1].complete = false
rebuild()
H.eq(order(), "", "an unfinished quest: no turn-in button, however near")
WoW.questLog[1].complete = true
rebuild()
H.eq(order(), "Orgnil Soulscar", "finished: the rebuild shows it at once, not at the next tick")
WoW.questLog = {}
rebuild()
H.eq(order(), "", "turned in (out of the log): gone")

------------------------------------------------------------
-- Two near turn-ins and a full frame: the reserved slot follows the nearer
-- one as the player walks (Codex on #69)
------------------------------------------------------------
do
    -- Orgnil's spawn is cached at 52, 43; Gornek stands 60 yd east of it.
    DB.Npc[3145] = { name = "Gornek", spawns = { [14] = { { 52.0 + 60 / W * 100, 43.0 } } } }
    DB.Quest[825] = { objectives = {}, finishedBy = { { 3145 } } }
    local rows, objs = {}, {}
    for i = 1, 8 do
        DB.Npc[200 + i] = { name = "Mob " .. i }
        rows[i] = { type = "monster", text = "0/5 Mob " .. i .. " slain" }
        objs[i] = { 200 + i }
    end
    DB.Quest[900] = { objectives = { objs } }
    WoW.questLog = {
        { questID = 900, title = "Cull", complete = false, rows = rows },
        { questID = 823, title = "Report to Orgnil", rows = {}, complete = true },
        { questID = 825, title = "Report to Gornek", rows = {}, complete = true },
    }
    stand(52, 43, 10)
    rebuild()
    for i = 1, 8 do
        WoW.SetUnit("nameplate" .. i, { name = "Mob " .. i, guid = "Creature-0-1-2-3-" .. (200 + i) .. "-A",
            plate = true, attackable = true })
        WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
    end
    local function turnins()
        local out = {}
        for _, b in ipairs(T.buttons) do
            if b.shown and (b.npcName == "Gornek" or b.npcName == "Orgnil Soulscar") then out[#out + 1] = b.npcName end
        end
        return table.concat(out, ",")
    end
    Q.Tick()
    H.eq(turnins(), "Orgnil Soulscar", "a full frame keeps one slot for a turn-in: the nearer one (10 yd vs 50)")
    stand(52, 43, 50); Q.Tick()
    H.eq(turnins(), "Gornek", "walked on, both still near: the slot follows the nearer one")
    for i = 1, 8 do WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate" .. i) end
    WoW.units = {}
    WoW.questLog = {}
    rebuild()
end

------------------------------------------------------------
-- A type-14 trainer: someone to talk to, also by their spawn
------------------------------------------------------------
DB.Npc[3087] = { name = "Cook Torka", spawns = { [14] = { { 51.0, 42.0 } } } }
DB.Quest[96655] = { objectives = { { { 3087 } } }, finishedBy = { { 3142 } } }
WoW.questLog = { { questID = 96655, title = "Camping 101: Cooking", complete = false,
    rows = { { type = "object", text = "Learn cooking from Cook Torka in Razor Hill", objectiveType = 14 } } } }
stand(51, 42, 30)
rebuild()
H.eq(order(), "Cook Torka", "a trainer to talk to, near his spawn: a button")
H.check(T.buttons[1].friendly, "...an NPC, not a kill target")
WoW.questLog = {}
rebuild()

------------------------------------------------------------
-- Droppers: a seen mob gets a button; mobs get no NEAR
------------------------------------------------------------
DB.Npc[3103].spawns = { [14] = { { 60.0, 80.0 } } }
DB.Quest[818] = { objectives = { nil, nil, { { 5002 } } }, finishedBy = { { 3142 } } }
WoW.questLog = { { questID = 818, title = "A Solvent Spirit", complete = false,
    rows = { { type = "item", text = "1/4 Intact Makrura Eye", numFulfilled = 1, numRequired = 4 } } } }
stand(60, 80, 5)
rebuild()
H.eq(order(), "", "a dropper's spawn 5 yd away gives no button: mobs need to be seen")
WoW.SetUnit("nameplate1", { name = "Makrura Clacker", guid = "Creature-0-1-2-3-3103-A", plate = true, attackable = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
H.eq(order(), "Makrura Clacker", "seen, the item's dropper gets a button")
H.check(not T.buttons[1].friendly, "...in the mob row")
WoW.units = {}
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
WoW.questLog = {}
rebuild()

------------------------------------------------------------
-- Questie ready: one rebuild with fresh data
------------------------------------------------------------
do
    local Questie = { API = { isReady = false } }
    rawset(_G, "Questie", Questie)
    WoW.events = {}
    WoW.timers = {}
    local T2, ns2 = WoW.loadAddon({ savedDB = { questTargets = true } })
    local function order2()
        local out = {}
        for _, b in ipairs(T2.buttons) do if b.shown then out[#out + 1] = b.npcName end end
        return table.concat(out, ",")
    end
    DB.Npc[3142].spawns = { [14] = { { 10.0, 10.0 } } }   -- what QuestieDB says before Questie's corrections
    WoW.questLog = { { questID = 823, title = "Report to Orgnil", rows = {}, complete = true } }
    stand(52, 43, 0)
    WoW.fire("QUEST_LOG_UPDATE")
    WoW.flushTimers()   -- the rebuild, and a first look at Questie: not ready
    H.eq(order2(), "", "before Questie is ready, the uncorrected spawn is far away")
    DB.Npc[3142].spawns = { [14] = { { 52.0, 43.0 } } }   -- Questie's correction
    Questie.API.isReady = true
    WoW.flushTimers()   -- ready: caches cleared, a rebuild scheduled
    WoW.flushTimers()   -- the rebuild
    H.eq(order2(), "Orgnil Soulscar", "once Questie is ready, the corrected data is read again")
    local pending = #WoW.timers
    WoW.flushTimers()
    H.eq(#WoW.timers, 0, "and it stops looking (" .. pending .. " timer(s) were left)")
    H.check(ns2.questData ~= nil, "the provider stays")
end

H.done("test_questie")
