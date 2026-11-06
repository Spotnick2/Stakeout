-------------------------------------------------------------------------------
-- Stakeout — QuestieDB as the quest targets' data provider (#24, Phase 3, #68)
--
-- Quests.lua asks ns.questData who a quest wants: its objectives' NPCs, the
-- NPCs that drop an item, who ends it and where an NPC stands. This file
-- answers from LibQuestieDB (the QuestieDB addon Questie ships), when it is
-- loaded and speaks the contract below. Without it nothing is set, and quest
-- targets keep their reduced subset.
--
-- What it relies on is measured in docs/FOREVER-PROBE.md, section 12 (P3, P4):
--   * LibQuestieDB is there at our load, and RequireContract(4) holds.
--   * Data reads work before Questie.API.isReady; one rebuild once it's ready
--     picks up anything Questie corrects at its own start.
--   * Spawn coordinates are already in Forever's frame: used as stored, never
--     through EraToForever.
--   * The area -> uiMap table is ZoneDB's areaIdToUiMapId string (and its
--     Override), parsed here as data and never run.
-------------------------------------------------------------------------------
local _, ns = ...

local tinsert = table.insert

local CONTRACT    = 4    -- the LibQuestieDB contract these reads are written for
local READY_POLL  = 1    -- seconds between looks at Questie.API.isReady
local READY_TRIES = 60   -- then stop looking: QuestieDB alone has no Questie

local lib             -- LibQuestieDB, once it is known to fit
local areaMap         -- [areaID] = uiMapID, or false when it couldn't be read
local spawnCache = {} -- [npcId] = Spawns(npcId)'s answer, or false for none

-- LibQuestieDB, if it's loaded and supports CONTRACT.
local function FindLib()
    local L = rawget(_G, "LibQuestieDB")
    if type(L) ~= "table" or type(L.RequireContract) ~= "function" then return nil end
    local ok, fits = pcall(L.RequireContract, CONTRACT)
    if ok and fits == true then return L end
    return nil
end

-- One field of one entity, or nil (unknown ID, a read that errors).
local function Get(entity, id, key)
    local e = lib and lib[entity]
    if type(e) ~= "table" or type(e.Get) ~= "function" then return nil end
    local ok, v = pcall(e.Get, id, key)
    if ok then return v end
    return nil
end

local function Text(v)
    return type(v) == "string" and v ~= "" and v or nil
end

local function List(v)
    return type(v) == "table" and v or {}
end

-------------------------------------------------------------------------------
-- The area -> uiMap table
-------------------------------------------------------------------------------
-- The area -> uiMap table, parsed as data and never run: comments stripped, a
-- `return { ... }` of `[area] = map` entries, and anything else rejects the
-- whole string. The probe's parser (Tools/StakeoutProbe), unchanged.
local function ParseAreaMap(s)
    if type(s) ~= "string" then return nil end
    local body = s:gsub("%-%-[^\n]*", "")
    local inner = body:match("^%s*return%s*(%b{})%s*$")
    if not inner then return nil end
    local map = {}
    local rest = inner:sub(2, -2):gsub("%[%s*(%d+)%s*%]%s*=%s*(%d+)", function(area, ui)
        map[tonumber(area)] = tonumber(ui)
        return ""
    end)
    if rest:match("[^%s,]") then return nil end
    return map
end

local function AreaMap()
    if areaMap ~= nil then return areaMap or nil end
    areaMap = false
    local ok, zone = pcall(function() return lib.Support.Get("ZoneDB") end)
    local private = ok and type(zone) == "table" and zone.private
    if type(private) ~= "table" then return nil end
    local base = ParseAreaMap(private.areaIdToUiMapId)
    if not base then return nil end
    -- The Override is Questie's own corrections; a bad one is skipped, not fatal.
    local over = ParseAreaMap(private.areaIdToUiMapIdOverride)
    if over then
        for area, ui in pairs(over) do base[area] = ui end
    end
    areaMap = base
    return areaMap
end

-------------------------------------------------------------------------------
-- The provider (Quests.lua documents the interface)
-------------------------------------------------------------------------------
local Provider = {}

-- A quest's objectives in Questie's own order (QuestieDB:GetQuest): creatures,
-- objects, items, kill credits, each group in its stored order, and a group
-- the ObjectiveFirst hints name put at the front one entry at a time, as
-- Questie does. Reputation, spell and event objectives aren't units and are
-- left out: the association pairs by row type, so their absence shifts
-- nothing. nil for a quest QuestieDB doesn't know, or one it stores oddly.
function Provider.Objectives(questID)
    local obj = Get("Quest", questID, "objectives")
    if type(obj) ~= "table" then return nil end
    local first = type(lib.ObjectiveFirst) == "table" and lib.ObjectiveFirst or {}
    local function hinted(set)
        return type(first[set]) == "table" and first[set][questID] == true
    end
    local list, bad = {}, false
    local function add(entry, front)
        if front then tinsert(list, 1, entry) else list[#list + 1] = entry end
    end
    local function group(raw, kind, entity, hint)
        local front = hint and hinted(hint)
        for _, e in ipairs(List(raw)) do
            if type(e) ~= "table" or type(e[1]) ~= "number" then
                bad = true
            else
                add({ kind = kind, id = e[1], name = Text(e[2]) or Text(Get(entity, e[1], "name")) }, front)
            end
        end
    end
    group(obj[1], "creature", "Npc")
    group(obj[2], "object", "Object", "objectObjectiveFirst")
    group(obj[3], "item", "Item", "itemObjectiveFirst")
    local front = hinted("killCreditObjectiveFirst")
    for _, e in ipairs(List(obj[5])) do
        if type(e) ~= "table" or type(e[2]) ~= "number" then
            bad = true
        else
            local ids = {}
            for _, id in ipairs(List(e[1])) do
                if type(id) == "number" then ids[#ids + 1] = id end
            end
            add({ kind = "killcredit", id = e[2], ids = ids,
                  name = Text(e[3]) or Text(Get("Npc", e[2], "name")) }, front)
        end
    end
    if bad then return nil end
    return list
end

function Provider.ItemDroppers(itemID)
    return Get("Item", itemID, "npcDrops")
end

function Provider.NpcName(npcID)
    return Text(Get("Npc", npcID, "name"))
end

-- NPCs only: an object that ends a quest isn't a unit to target.
function Provider.FinishedBy(questID)
    local fin = Get("Quest", questID, "finishedBy")
    return type(fin) == "table" and fin[1] or nil
end

-- Where an NPC stands: { [uiMapID] = { { x, y }, ... } }, x and y in 0..1 of
-- that map. QuestieDB stores { [areaID] = { { x, y }, ... } } in 0..100;
-- negative points are its "no position" sentinel. Cached: spawns don't move.
function Provider.Spawns(npcID)
    local cached = spawnCache[npcID]
    if cached ~= nil then return cached or nil end
    spawnCache[npcID] = false
    local spawns = Get("Npc", npcID, "spawns")
    local map = type(spawns) == "table" and AreaMap()
    if not map then return nil end
    local out, any = {}, false
    for area, points in pairs(spawns) do
        local ui = type(area) == "number" and map[area]
        if ui and ui > 0 then
            for _, pt in ipairs(List(points)) do
                local x, y = type(pt) == "table" and pt[1], type(pt) == "table" and pt[2]
                if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 and x <= 100 and y <= 100 then
                    out[ui] = out[ui] or {}
                    local list = out[ui]
                    list[#list + 1] = { x / 100, y / 100 }
                    any = true
                end
            end
        end
    end
    if not any then return nil end
    spawnCache[npcID] = out
    return out
end

-------------------------------------------------------------------------------
-- Hooking up
-------------------------------------------------------------------------------
local function Rebuild()
    local quests = ns.quests
    if quests and quests.Enabled and quests.Enabled() and quests.ScheduleRebuild then
        quests.ScheduleRebuild()
    end
end

-- Set the provider once LibQuestieDB is there; true when it is.
local function Attach()
    if lib then return true end
    lib = FindLib()
    if not lib then return false end
    ns.questData = Provider
    return true
end

-- Questie corrects QuestieDB at its own start: once it's ready, read again.
local function QuestieReady()
    local ok, ready = pcall(function()
        local Q = rawget(_G, "Questie")
        return type(Q) == "table" and type(Q.API) == "table" and Q.API.isReady == true
    end)
    return ok and ready
end

local tries = 0
local function WatchReady()
    if QuestieReady() then
        wipe(spawnCache)
        areaMap = nil
        Rebuild()
        return
    end
    tries = tries + 1
    if tries < READY_TRIES then C_Timer.After(READY_POLL, WatchReady) end
end

Attach()

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function()
    eventFrame:UnregisterEvent("PLAYER_LOGIN")
    if Attach() then
        Rebuild()
        WatchReady()
    end
end)
ns.core.RegisterEvents(eventFrame, "PLAYER_LOGIN")

-- Test seam (tests/). Harmless in game.
ns.questieData = {
    Provider = Provider, ParseAreaMap = ParseAreaMap,
    attached = function() return lib ~= nil end,
}
