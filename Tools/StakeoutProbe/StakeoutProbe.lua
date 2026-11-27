-- StakeoutProbe: a throwaway measuring addon for Stakeout (never shipped).
-- A ForeverProbe module (..\ForeverProbe\docs\GUIDE.md): its lines go to the
-- /fp console and StakeoutProbeDB.log, never to chat. It measures what quest
-- targeting (#24) relies on, on build 70450 (#25):
--   P1  the quest log's objective rows, IsComplete vs ReadyForTurnIn
--   P2  whether a quest unit's name, GUID and creature ID are secret, in and
--       out of combat; UnitIsRelatedToActiveQuest; QuestieDB's name vs the client's
--   P3  whether QuestieDB's spawn coordinates match where the player stands on
--       this client (as stored, and as if they were Era coordinates), and
--       whether map distance agrees with world distance
--   P4  LibQuestieDB's timing and contract, the area -> uiMap table, read cost
--   P5  how far /targetexact reaches without a nameplate; /tm 8 vs /tm !8
--   P6  units already visible at login; quest event order
--   P8  Stakeout's own click, mark and UNIT_DIED behaviour, re-checked
--
--   /fp so state            build, combat, position, QuestieDB and Questie
--   /fp so log              every quest in the log: its rows, and QuestieDB's data
--   /fp so unit [token]     who a unit is (default: target)
--   /fp so plates           the same, short, for every nameplate
--   /fp so spawns [npcId]   QuestieDB's spawns for an NPC (default: the target's) and the distance to them
--   /fp so near             each quest target's nearest spawn on this map: the feature, previewed
--   /fp so mark | walk      remember this spot | compare map and world distance from it
--   /fp so questie          LibQuestieDB, its contract, the area map, read cost
--   /fp so button <name> [mark] | button off   a secure test button: left /targetexact, right adds /tm <mark>
--   /fp so events on|off    log quest and death events, and objective changes
--   /fp so clear            empty the saved log
--
--   /fp so hud ... | face    the list layout mockups (#88): Hud.lua
--
-- Procedures: /fp steps so quests, range, events, core, mulgore, corpse, tagged (#95); hud (Hud.lua).

local ADDON, NS = ...
local MAX_LOG = 4000

local Probe = ForeverProbe:Module("StakeoutProbe", { api = 1, cmd = "so" })
NS.Probe = Probe   -- for Hud.lua

local function say(msg) Probe:Say(msg) end
local function str(v) return Probe.Show(v, true) end
-- Client APIs are read with rawget: one this client lacks is reported, not thrown.
local function G(name) return rawget(_G, name) end
local function secret(v)
    local fn = G("issecretvalue")
    return fn ~= nil and fn(v) == true
end
-- A number or string we can use, or nil (missing or secret).
local function num(v) if type(v) == "number" and not secret(v) then return v end end
local function text(v) if type(v) == "string" and not secret(v) then return v end end
local function call(fn, ...)
    if type(fn) ~= "function" then return false, "MISSING" end
    return pcall(fn, ...)
end
local function api(lib, fn)
    local t = G(lib)
    return type(t) == "table" and t[fn] or nil
end
local function now()
    local ok, v = call(G("debugprofilestop"))
    return ok and num(v) or nil
end
local function ms(t0, t1) return (t0 and t1) and ("%.1f"):format(t1 - t0) or "-" end
local function inCombat()
    local ok, v = call(G("InCombatLockdown"))
    return ok and v == true
end

-- This session: the units read last (mob, npc), the test button's target and
-- clicks, the marked spot, the event logger, the login samples.
local state = { clicks = 0, samples = {} }

--------------------------------------------------------------------------------
-- QuestieDB (optional)
--------------------------------------------------------------------------------

local function lib()
    local L = G("LibQuestieDB")
    if type(L) == "table" then return L end
end

local function entity(name)
    local L = lib()
    local e = L and L[name]
    if type(e) == "table" and type(e.Get) == "function" then return e end
end

local function dbGet(name, id, key)
    local e = entity(name)
    if not e then return nil end
    local ok, v = pcall(e.Get, id, key)
    if ok then return v end
end

-- The area -> uiMap table, parsed as data and never run: comments stripped, a
-- `return { ... }` of `[area] = map` entries, and anything else rejects the
-- whole string. Stakeout's adapter will use this parser.
local function parseAreaMap(s)
    if type(s) ~= "string" then return nil, "not a string (" .. type(s) .. ")" end
    local body = s:gsub("%-%-[^\n]*", "")
    local inner = body:match("^%s*return%s*(%b{})%s*$")
    if not inner then return nil, "not `return { ... }`" end
    local map, n = {}, 0
    local rest = inner:sub(2, -2):gsub("%[%s*(%d+)%s*%]%s*=%s*(%d+)", function(area, ui)
        map[tonumber(area)] = tonumber(ui)
        n = n + 1
        return ""
    end)
    local junk = rest:match("[^%s,][^\n]*")
    if junk then return nil, "unexpected text: " .. junk:sub(1, 40) end
    return map, n
end

local areaMap, areaMapWhy
local function areaToUiMap()
    if areaMap or areaMapWhy then return areaMap, areaMapWhy end
    local L = lib()
    local ok, zone = pcall(function() return L.Support.Get("ZoneDB") end)
    local private = ok and type(zone) == "table" and zone.private
    if type(private) ~= "table" then
        areaMapWhy = "no Support ZoneDB"
        return nil, areaMapWhy
    end
    local base, why = parseAreaMap(private.areaIdToUiMapId)
    if not base then
        areaMapWhy = "base: " .. why
        return nil, areaMapWhy
    end
    local over, whyOver = parseAreaMap(private.areaIdToUiMapIdOverride)
    if over then
        for area, ui in pairs(over) do base[area] = ui end
    else
        say("area map override not used: " .. whyOver)
    end
    areaMap = base
    return areaMap
end

-- Questie's ordering hints for one quest, as "kc item object ..." or "none".
local function firstHints(questID)
    local L = lib()
    local of = L and L.ObjectiveFirst
    if type(of) ~= "table" then return "no ObjectiveFirst" end
    local out = {}
    for _, k in ipairs({ "killCreditObjectiveFirst", "objectObjectiveFirst", "itemObjectiveFirst",
                         "eventObjectiveFirst", "spellObjectiveFirst" }) do
        if type(of[k]) == "table" and of[k][questID] then out[#out + 1] = k end
    end
    return #out > 0 and table.concat(out, " ") or "none"
end

local function idList(t, nameOf, limit)
    if type(t) ~= "table" then return "-" end
    local out = {}
    for i, id in ipairs(t) do
        if limit and i > limit then
            out[#out + 1] = "... " .. (#t - limit) .. " more"
            break
        end
        out[#out + 1] = tostring(id) .. (nameOf and (" " .. str(nameOf(id))) or "")
    end
    return "[" .. table.concat(out, ", ") .. "]"
end

local function npcName(id) return dbGet("Npc", id, "name") end
local function itemName(id) return dbGet("Item", id, "name") end
local function objectName(id) return dbGet("Object", id, "name") end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- The player's map position, with the map's size in yards; nil and why.
local function playerPos()
    local ok, map = call(api("C_Map", "GetBestMapForUnit"), "player")
    map = ok and num(map)
    if not map then return nil, "no map (" .. str(map) .. ")" end
    local ok2, pos = call(api("C_Map", "GetPlayerMapPosition"), map, "player")
    if not ok2 or pos == nil or secret(pos) then return nil, "no position on map " .. map end
    local ok3, x, y = pcall(pos.GetXY, pos)
    x, y = ok3 and num(x), ok3 and num(y)
    if not (x and y) then return nil, "position unreadable on map " .. map end
    local ok4, w, h = call(api("C_Map", "GetMapWorldSize"), map)
    w, h = ok4 and num(w), ok4 and num(h)
    if not (w and h) or w <= 0 or h <= 0 then return nil, "no world size for map " .. map end
    return { map = map, x = x, y = y, w = w, h = h }
end

-- Yards from the player to a point given in 0..1 on the player's map.
local function yards(p, sx, sy)
    return math.sqrt(((p.x - sx) * p.w) ^ 2 + ((p.y - sy) * p.h) ^ 2)
end

local function fmt(d) return d and ("%.1f"):format(d) or "-" end

-- An NPC's nearest QuestieDB spawn on the player's map: as stored, and as if
-- the data were Era coordinates (LibQuestieDB.EraToForever). Logs each area.
-- Returns the stored distance (or nil and why).
local function spawnDistance(npcId, quiet)
    local spawns = dbGet("Npc", npcId, "spawns")
    if type(spawns) ~= "table" then return nil, "no QuestieDB spawns" end
    local map, why = areaToUiMap()
    if not map then return nil, why end
    local p, whyPos = playerPos()
    local L = lib()
    local best, bestEra, bestPt
    for area, points in pairs(spawns) do
        local ui = map[area]
        local same = p and ui == p.map
        if not quiet then
            say(("  spawns in area %s -> uiMap %s: %d points%s"):format(str(area), str(ui),
                type(points) == "table" and #points or 0, same and " (this map)" or ""))
        end
        if same and type(points) == "table" then
            for _, pt in ipairs(points) do
                local sx, sy = num(pt[1]), num(pt[2])
                if sx and sy and sx >= 0 and sy >= 0 then
                    local d = yards(p, sx / 100, sy / 100)
                    if not best or d < best then best, bestPt = d, pt end
                    if L and type(L.EraToForever) == "function" then
                        local ok, ex, ey = pcall(L.EraToForever, area, sx, sy)
                        if ok and num(ex) then
                            local de = yards(p, ex / 100, ey / 100)
                            if not bestEra or de < bestEra then bestEra = de end
                        end
                    end
                end
            end
        end
    end
    if not p then return nil, whyPos end
    if not quiet then
        say(("  player on map %d at %.2f, %.2f (map %.0f x %.0f yd); nearest spawn %s yd at %s, %s; as Era-converted %s yd")
            :format(p.map, p.x * 100, p.y * 100, p.w, p.h, fmt(best), str(bestPt and bestPt[1]),
                str(bestPt and bestPt[2]), fmt(bestEra)))
    end
    if not best then return nil, "no spawn on this map" end
    return best, bestEra
end

--------------------------------------------------------------------------------
-- Units
--------------------------------------------------------------------------------

local function npcIdFromGuid(guid)
    local g = text(guid)
    if not g then return nil end
    local kind, id = g:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

-- Who a unit is. Returns { name, id, friendly, plate, combat } with what was plain.
local function unitReport(token, short)
    token = token or "target"
    local okE, exists = call(G("UnitExists"), token)
    if not (okE and exists == true) then
        say("unit " .. token .. ": none")
        return nil
    end
    local _, isPlayer = call(G("UnitIsPlayer"), token)
    if isPlayer == true then
        say("unit " .. token .. ": a player (not logged)")
        return nil
    end
    local _, name = call(G("UnitName"), token)
    local _, guid = call(G("UnitGUID"), token)
    local _, cid = call(G("UnitCreatureID"), token)
    local okR, related = call(api("C_QuestLog", "UnitIsRelatedToActiveQuest"), token)
    local _, attack = call(G("UnitCanAttack"), "player", token)
    local _, reaction = call(G("UnitReaction"), token, "player")
    local _, dead = call(G("UnitIsDead"), token)
    local okP, plate = call(api("C_NamePlate", "GetNamePlateForUnit"), token)
    local _, mark = call(G("GetRaidTargetIndex"), token)
    local combat = inCombat()
    local id = npcIdFromGuid(guid) or num(cid)
    local r = {
        name = text(name), id = id, combat = combat,
        friendly = attack == false, plate = okP and plate ~= nil,
    }
    say(("unit %s: name %s (%s) guid %s creatureID %s related %s attackable %s reaction %s dead %s plate %s mark %s combat %s")
        :format(token, short and str(name) or Probe.Show(name), Probe.Shape(name), short and Probe.Shape(guid) or str(guid),
            str(cid), okR and str(related) or ("ERROR " .. str(related)), str(attack), str(reaction), str(dead),
            tostring(r.plate), str(mark), tostring(combat)))
    if id and not short and lib() then
        local dbName = npcName(id)
        say(("  questie npc %d: name %s, %s the client's; starts %s ends %s"):format(id, str(dbName),
            (r.name and dbName == r.name) and "same as" or "NOT", idList(dbGet("Npc", id, "questStarts")),
            idList(dbGet("Npc", id, "questEnds"))))
    end
    return r
end

--------------------------------------------------------------------------------
-- Quest log
--------------------------------------------------------------------------------

-- Every quest (not header) in the log: { questID, title, index }.
local function questLog()
    local list = {}
    local ok, n = call(api("C_QuestLog", "GetNumQuestLogEntries"))
    for i = 1, (ok and num(n)) or 0 do
        local okI, info = call(api("C_QuestLog", "GetInfo"), i)
        if okI and type(info) == "table" and not info.isHeader then
            local id = num(info.questID)
            if id and id > 0 then
                list[#list + 1] = { questID = id, title = text(info.title), index = i, hidden = info.isHidden }
            end
        end
    end
    return list
end

local function objectives(questID)
    local ok, rows = call(api("C_QuestLog", "GetQuestObjectives"), questID)
    if ok and type(rows) == "table" then return rows end
    return {}
end

-- A quest's rows, compressed: "monster 0/8 F" per row.
local function summary(questID)
    local out = {}
    for _, o in ipairs(objectives(questID)) do
        out[#out + 1] = ("%s %s/%s%s"):format(str(o.type), str(o.numFulfilled), str(o.numRequired),
            o.finished == true and " done" or "")
    end
    local _, complete = call(api("C_QuestLog", "IsComplete"), questID)
    return table.concat(out, "; ") .. (complete == true and " | complete" or "")
end

local function logQuest(q)
    local _, complete = call(api("C_QuestLog", "IsComplete"), q.questID)
    local _, ready = call(api("C_QuestLog", "ReadyForTurnIn"), q.questID)
    local rows = objectives(q.questID)
    say(("Q %d %s: IsComplete %s ReadyForTurnIn %s, %d rows%s"):format(q.questID, str(q.title), str(complete),
        str(ready), #rows, q.hidden and " (hidden)" or ""))
    for i, o in ipairs(rows) do
        say(("  row %d: type %s finished %s %s/%s objectiveType %s text %s"):format(i, str(o.type), str(o.finished),
            str(o.numFulfilled), str(o.numRequired), str(o.objectiveType), Probe.Show(o.text)))
    end
    if not lib() then return end
    local obj = dbGet("Quest", q.questID, "objectives")
    local fin = dbGet("Quest", q.questID, "finishedBy")
    if type(obj) ~= "table" then
        say("  questie: no objectives row")
    else
        local function group(i, label, nameOf)
            local g = obj[i]
            if type(g) ~= "table" or #g == 0 then return end
            local out = {}
            for _, e in ipairs(g) do
                if type(e) == "table" then
                    if label == "killcredit" then
                        out[#out + 1] = ("%s root %s %s"):format(idList(e[1]), str(e[2]), Probe.Show(e[3]))
                    else
                        local extra = ""
                        if label == "item" then
                            local drops = dbGet("Item", e[1], "npcDrops")
                            extra = " droppers " .. idList(drops, npcName, 6)
                        end
                        out[#out + 1] = ("%s %s%s%s"):format(str(e[1]), str(nameOf and nameOf(e[1])),
                            e[2] and (" text " .. Probe.Show(e[2])) or "", extra)
                    end
                end
            end
            say(("  questie %s: %s"):format(label, table.concat(out, "; ")))
        end
        group(1, "creature", npcName)
        group(2, "object", objectName)
        group(3, "item", itemName)
        group(5, "killcredit")
    end
    say(("  questie finishedBy npc %s object %s; first: %s"):format(
        idList(type(fin) == "table" and fin[1] or nil, npcName), idList(type(fin) == "table" and fin[2] or nil),
        firstHints(q.questID)))
end

-- Each quest target this would show, with its nearest spawn on this map:
-- kill and item mobs while the quest is open, the finisher once it's complete.
local function near()
    if not lib() then
        say("near: no QuestieDB")
        return
    end
    local found = {}
    for _, q in ipairs(questLog()) do
        local _, complete = call(api("C_QuestLog", "IsComplete"), q.questID)
        local ids = {}
        if complete == true then
            local fin = dbGet("Quest", q.questID, "finishedBy")
            for _, id in ipairs(type(fin) == "table" and type(fin[1]) == "table" and fin[1] or {}) do
                ids[#ids + 1] = { id = id, kind = "turnin" }
            end
        else
            local obj = dbGet("Quest", q.questID, "objectives") or {}
            for _, e in ipairs(type(obj[1]) == "table" and obj[1] or {}) do
                ids[#ids + 1] = { id = e[1], kind = "kill" }
            end
            for _, e in ipairs(type(obj[5]) == "table" and obj[5] or {}) do
                for _, id in ipairs(type(e[1]) == "table" and e[1] or {}) do ids[#ids + 1] = { id = id, kind = "kill" } end
            end
            for _, e in ipairs(type(obj[3]) == "table" and obj[3] or {}) do
                for _, id in ipairs(dbGet("Item", e[1], "npcDrops") or {}) do ids[#ids + 1] = { id = id, kind = "item" } end
            end
        end
        for _, t in ipairs(ids) do
            local d = spawnDistance(t.id, true)
            found[#found + 1] = { quest = q, id = t.id, kind = t.kind, d = d }
        end
    end
    table.sort(found, function(a, b) return (a.d or 1e9) < (b.d or 1e9) end)
    say(("near: %d targets"):format(#found))
    for i, t in ipairs(found) do
        if i > 25 then
            say("  ...")
            break
        end
        say(("  %s %s (%d) for %s: %s yd"):format(t.kind, str(npcName(t.id)), t.id, str(t.quest.title), fmt(t.d)))
    end
end

--------------------------------------------------------------------------------
-- The test button (P5)
--------------------------------------------------------------------------------

local button
local function onClick(_, which, down)
    state.clicks = state.clicks + 1
    local _, exists = call(G("UnitExists"), "target")
    local _, isPlayer = call(G("UnitIsPlayer"), "target")
    local _, name = call(G("UnitName"), "target")
    if isPlayer == true then name = "<a player>" end
    local okP, plate = call(api("C_NamePlate", "GetNamePlateForUnit"), "target")
    local _, mark = call(G("GetRaidTargetIndex"), "target")
    local _, dead = call(G("UnitIsDead"), "target")
    local _, guid = call(G("UnitGUID"), "target")
    -- The GUID's last part tells two units of one name apart (which one a click landed on)
    local uid = exists == true and text(guid) and guid:match("%-(%x+)$") or nil
    local d = state.aim and state.aim.id and spawnDistance(state.aim.id, true)
    state.lastClick = {
        target = exists == true and text(name) or nil, plate = okP and plate ~= nil, mark = num(mark),
        wanted = state.aim and state.aim.name, d = d, dead = exists == true and dead == true, uid = uid,
    }
    say(("click %s %s: target %s (wanted %s) plate %s mark %s dead %s unit %s; %s yd from its nearest spawn")
        :format(str(which), down and "down" or "up", exists == true and str(name) or "none",
        str(state.lastClick.wanted), tostring(state.lastClick.plate), str(mark), tostring(state.lastClick.dead),
        str(uid), fmt(d)))
end

-- left: the left-click macro, with <name> for the name (default: /cleartarget, /targetexact <name>)
local function aim(name, id, mark, left)
    if inCombat() then return false, "in combat: the button can't change" end
    if type(name) ~= "string" or name == "" or name:find("%c") then return false, "no usable name" end
    if not button then
        button = CreateFrame("Button", "StakeoutProbeButton", UIParent, "SecureActionButtonTemplate")
        button:SetSize(44, 44)
        button:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
        button:RegisterForClicks("AnyUp", "AnyDown")
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(button)
        icon:SetTexture(134400)                               -- the question mark icon
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.label:SetPoint("TOP", button, "BOTTOM", 0, -2)
        button:HookScript("PostClick", onClick)
    end
    mark = mark or "8"
    button:SetAttribute("type", "macro")
    left = (left or "/cleartarget\n/targetexact <name>"):gsub("<name>", function() return name end)
    button:SetAttribute("macrotext", left)
    button:SetAttribute("type2", "macro")
    button:SetAttribute("macrotext2", "/cleartarget\n/targetexact " .. name .. "\n/tm " .. mark)
    button.label:SetText("probe: " .. name .. " (right: /tm " .. mark .. ")")
    button:Show()
    -- Every new macro is a new aim: a procedure's trial for an older one ends.
    state.aimGen = (state.aimGen or 0) + 1
    state.aim = { name = name, id = id, mark = mark }
    say(("button: left %s; right targets %s, then /tm %s"):format((left:gsub("\n", " | ")), name, mark))
    return true
end

local function buttonOff()
    if not button then return true end
    if inCombat() then return false, "in combat" end
    button:Hide()
    say("button hidden")
    return true
end

-- A wait step: done once the button has been clicked since the step began.
local function clickedSince(n0)
    if state.clicks > n0 then
        local c = state.lastClick
        return true, c.target, c.plate, c.mark, c.d, c.dead, c.uid
    end
    return false, "waiting for a click"
end

--------------------------------------------------------------------------------
-- Events (P6)
--------------------------------------------------------------------------------

local EVENTS = { "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_WATCH_UPDATE", "QUEST_LOG_UPDATE",
                 "UNIT_QUEST_LOG_CHANGED", "QUEST_COMPLETE", "QUEST_PROGRESS", "QUEST_DETAIL", "GOSSIP_SHOW",
                 "UNIT_DIED", "QUEST_POI_UPDATE" }
local logger = CreateFrame("Frame")
local registered = false

local function diffObjectives()
    state.last = state.last or {}
    for _, q in ipairs(questLog()) do
        local s = summary(q.questID)
        if state.last[q.questID] ~= s then
            say(("  Q %d now: %s"):format(q.questID, s))
            state.last[q.questID] = s
        end
    end
end

logger:SetScript("OnEvent", function(_, event, ...)
    if not state.logging then return end
    state.counts[event] = (state.counts[event] or 0) + 1
    if event == "QUEST_LOG_UPDATE" or event == "UNIT_QUEST_LOG_CHANGED" then
        say("EVENT " .. event .. " " .. str((...)))
        diffObjectives()
        return
    end
    local args = Probe.Pack(...)
    local out = {}
    for i = 1, args.n do out[i] = Probe.Show(args[i]) end
    say("EVENT " .. event .. " " .. table.concat(out, " "))
end)

local function events(on)
    if on then
        if not registered then
            Probe:RegisterEvents(logger, EVENTS)
            registered = true
        end
        state.logging, state.counts, state.last = true, {}, {}
        diffObjectives()
        say("events: logging")
    else
        state.logging = false
        local out = {}
        for e, n in pairs(state.counts or {}) do out[#out + 1] = e .. "=" .. n end
        table.sort(out)
        say("events: stopped; " .. table.concat(out, " "))
    end
    return true
end

--------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------

local function questieReport()
    local L = lib()
    if not L then
        say("questie: no LibQuestieDB")
        return false
    end
    local okC, cOk, cMsg = call(L.RequireContract, 4)
    say(("questie: LibQuestieDB %s, readMode %s, contract %s (min %s); RequireContract(4) %s %s"):format(
        str(L.addonName), str(L.readMode), str(L.contractVersion), str(L.minSupportedContract),
        okC and str(cOk) or "ERROR", str(cMsg)))
    for _, e in ipairs({ "Quest", "Npc", "Item", "Object" }) do
        if not entity(e) then say("  entity " .. e .. ": MISSING") end
    end
    local of = L.ObjectiveFirst
    if type(of) == "table" then
        local out = {}
        for k, t in pairs(of) do
            local n = 0
            if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
            out[#out + 1] = k .. "=" .. n
        end
        table.sort(out)
        say("  ObjectiveFirst: " .. table.concat(out, " "))
    else
        say("  ObjectiveFirst: " .. type(of))
    end
    say("  EraToForever: " .. type(L.EraToForever))
    local t0 = now()
    local map, why = areaToUiMap()
    local t1 = now()
    if map then
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        say(("  area map: %d areas in %s ms; 14 -> %s, 362 -> %s, 215 -> %s, 1637 -> %s"):format(n, ms(t0, t1),
            str(map[14]), str(map[362]), str(map[215]), str(map[1637])))
    else
        say("  area map: " .. why)
    end
    local qa = G("Questie")
    local qapi = type(qa) == "table" and qa.API
    say(("  Questie.API %s, isReady %s"):format(type(qapi), str(type(qapi) == "table" and qapi.isReady)))
    local reads, s0 = 0, now()
    for _, q in ipairs(questLog()) do
        local obj = dbGet("Quest", q.questID, "objectives")
        dbGet("Quest", q.questID, "finishedBy")
        reads = reads + 2
        for _, e in ipairs(type(obj) == "table" and type(obj[1]) == "table" and obj[1] or {}) do
            dbGet("Npc", e[1], "name"); dbGet("Npc", e[1], "spawns")
            reads = reads + 2
        end
    end
    say(("  %d reads for the quest log in %s ms"):format(reads, ms(s0, now())))
    return cOk == true
end

local function stateReport()
    local okB, version, build = call(G("GetBuildInfo"))
    say(("client %s %s, combat %s"):format(str(okB and version), str(okB and build), tostring(inCombat())))
    local p, why = playerPos()
    if p then
        say(("position: map %d at %.2f, %.2f; map %.0f x %.0f yd"):format(p.map, p.x * 100, p.y * 100, p.w, p.h))
    else
        say("position: " .. why)
    end
    local okW, wx, wy, wz, wmap = call(G("UnitPosition"), "player")
    say(("UnitPosition: %s, %s, %s on %s"):format(str(okW and wx), str(okW and wy), str(okW and wz), str(okW and wmap)))
    local okI, inInstance, kind = call(G("IsInInstance"))
    say(("IsInInstance: %s %s"):format(str(okI and inInstance), str(okI and kind)))
    say(("LibQuestieDB %s, Questie %s"):format(type(G("LibQuestieDB")), type(G("Questie"))))
end

local function plates()
    local ok, list = call(api("C_NamePlate", "GetNamePlates"))
    if not ok or type(list) ~= "table" then
        say("plates: " .. str(list))
        return 0
    end
    say(("plates: %d"):format(#list))
    for _, plate in ipairs(list) do
        local token = type(plate) == "table" and plate.namePlateUnitToken
        if text(token) then unitReport(token, true) end
    end
    return #list
end

-- A login-phase sample (P6): what is already readable at that moment.
local function sample(phase)
    local ok, list = call(api("C_NamePlate", "GetNamePlates"))
    local n, named, related = 0, 0, 0
    for _, plate in ipairs(ok and type(list) == "table" and list or {}) do
        n = n + 1
        local token = type(plate) == "table" and text(plate.namePlateUnitToken)
        if token then
            local _, name = call(G("UnitName"), token)
            if text(name) then named = named + 1 end
            local _, r = call(api("C_QuestLog", "UnitIsRelatedToActiveQuest"), token)
            if r == true then related = related + 1 end
        end
    end
    local L = lib()
    local qa = G("Questie")
    local line = ("sample %s: %d plates, %d named, %d quest-related; %d quests; LibQuestieDB %s; Questie ready %s")
        :format(phase, n, named, related, #questLog(), L and "yes" or "no",
            str(type(qa) == "table" and type(qa.API) == "table" and qa.API.isReady))
    state.samples[#state.samples + 1] = line
    say(line)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function targetNpc(args)
    local id = tonumber(args and args:match("%d+"))
    if id then return id end
    local r = unitReport("target", true)
    return r and r.id
end

Probe:Command("state", function() stateReport() end, "build, combat, position, QuestieDB and Questie")
Probe:Command("log", function()
    local list = questLog()
    say(("log: %d quests"):format(#list))
    for _, q in ipairs(list) do logQuest(q) end
end, "every quest in the log: its rows, and QuestieDB's data")
Probe:Command("unit", function(args)
    local token = args and args:match("%S+") or "target"
    local r = unitReport(token)
    if r and r.id then spawnDistance(r.id) end
end, "who a unit is (default: target)")
Probe:Command("plates", function() plates() end, "every nameplate, short")
Probe:Command("spawns", function(args)
    local id = targetNpc(args)
    if not id then return say("spawns: no NPC ID (target one, or /fp so spawns <id>)") end
    say(("spawns for %d %s:"):format(id, str(npcName(id))))
    local d, why = spawnDistance(id)
    if not d then say("  " .. str(why)) end
end, "QuestieDB's spawns for an NPC (default: the target's)")
Probe:Command("near", function() near() end, "each quest target's nearest spawn on this map")
Probe:Command("mark", function()
    local p, why = playerPos()
    local ok, wx, wy = call(G("UnitPosition"), "player")
    state.mark = p and { p = p, wx = ok and num(wx), wy = ok and num(wy) }
    say(p and ("marked: map %d at %.2f, %.2f; world %s, %s"):format(p.map, p.x * 100, p.y * 100, str(wx), str(wy))
        or ("mark: " .. why))
end, "remember this spot")
Probe:Command("walk", function()
    local m = state.mark
    if not m then return say("walk: mark a spot first") end
    local p, why = playerPos()
    if not p then return say("walk: " .. why) end
    if p.map ~= m.p.map then return say("walk: changed map, mark again") end
    local dMap = yards(p, m.p.x, m.p.y)
    local ok, wx, wy = call(G("UnitPosition"), "player")
    wx, wy = ok and num(wx), ok and num(wy)
    local dWorld = (wx and m.wx) and math.sqrt((wx - m.wx) ^ 2 + (wy - m.wy) ^ 2)
    state.walk = { map = dMap, world = dWorld }
    say(("walk: %s yd on the map, %s yd in the world, ratio %s"):format(fmt(dMap), fmt(dWorld),
        dWorld and dWorld > 0 and ("%.3f"):format(dMap / dWorld) or "-"))
end, "compare map and world distance from the marked spot")
Probe:Command("questie", function() questieReport() end, "LibQuestieDB, its contract, the area map, read cost")
Probe:Command("button", function(args)
    local rest = args or ""
    if rest:match("^%s*off%s*$") then
        local ok, why = buttonOff()
        if not ok then say("button: " .. why) end
        return
    end
    local name, mark = rest:match("^%s*(.-)%s+(!?%d)%s*$")
    name = name or rest:match("^%s*(.-)%s*$")
    local ok, why = aim(name, nil, mark)
    if not ok then say("button: " .. why) end
end, "<name> [mark]: a secure test button (left targets, right also marks); off to hide it")
Probe:Command("events", function(args)
    events(not (args and args:match("off")))
end, "on|off: log quest and death events, and objective changes")
Probe:Command("clear", function()
    Probe:ClearLog()
    say("log cleared")
end, "empty the saved log")

--------------------------------------------------------------------------------
-- Procedures
--------------------------------------------------------------------------------

-- Reads the target into state[slot] and logs its spawns; the step's result.
local function readTarget(slot)
    local r = unitReport("target")
    if not r then return false, "no target" end
    state[slot] = r
    local d, era = nil, nil
    if r.id then d, era = spawnDistance(r.id) end
    return r.name ~= nil, r.name, r.id, r.combat, d, era
end

Probe:Steps("quests", {
    rev = 1,
    title = "Stakeout: quest data (P1-P4)",
    { text = "Have Questie on, out of combat, where your quests are: at least one quest to kill mobs, one that "
          .. "needs items mobs drop and, if you can, one ready to turn in. Then press Next." },
    { text = "Reading QuestieDB.", auto = true, run = function() return questieReport() end },
    { text = "Reading your quest log.", auto = true, run = function()
          local list = questLog()
          for _, q in ipairs(list) do logQuest(q) end
          return #list
      end },
    { text = "Target a mob your kill quest needs, then press Read target.", button = "Read target",
      run = function() return readTarget("mob") end },
    { text = "Attack it. While you are in combat with it, press Read target.", button = "Read target",
      run = function() return readTarget("mobCombat") end,
      check = function() return state.mobCombat and state.mobCombat.combat, "read in combat" end },
    { text = "Target a mob that drops an item one of your quests needs, then press Read target.",
      button = "Read target", run = function() return readTarget("dropper") end },
    { text = "Target an NPC that has nothing to do with your quests (a guard or a vendor), then press Read target.",
      button = "Read target", run = function() return readTarget("unrelated") end },
    { text = "Go to the NPC you will turn a quest in to (Orgnil Soulscar in Razor Hill, for instance). Stand right "
          .. "next to him, target him, then press Read target.", button = "Read target",
      run = function() return readTarget("npc") end,
      check = function()
          local d = state.npc and state.npc.id and spawnDistance(state.npc.id, true)
          return d ~= nil and d <= 10, "nearest QuestieDB spawn " .. fmt(d) .. " yd away"
      end, screenshot = "turn-in NPC" },
    { text = "What the quest buttons would see around you.", auto = true, run = function() near(); return true end },
    { text = "Stand still and press Mark.", button = "Mark",
      run = function() SlashCmdList.FOREVERPROBE("so mark"); return state.mark ~= nil end },
    { text = "Walk about 30 yards in a straight line, then press Measure.", button = "Measure",
      run = function()
          SlashCmdList.FOREVERPROBE("so walk")
          return state.walk ~= nil, state.walk and state.walk.map, state.walk and state.walk.world
      end,
      check = function()
          local w = state.walk
          if not (w and w.world and w.world > 5) then return false, "no world distance" end
          local r = w.map / w.world
          return r > 0.95 and r < 1.05, ("map/world %.3f"):format(r)
      end },
    { text = "If you can, stand where quest mobs' nameplates are on screen. Then reload (Reload now, or /reload).",
      reload = true },
    { text = "The login samples.", auto = true, run = function()
          for _, l in ipairs(state.samples) do say("  " .. l) end
          return #state.samples
      end },
})

-- Stakeout's procedure for the range of /targetexact, at each distance.
local function rangeSteps(def)
    for _, yd in ipairs({ 40, 60, 80, 100 }) do
        local n0
        def[#def + 1] = {
            text = ("Walk away from him until you are about %d yards from where he stands (the step sees it). "
                .. "Press Done if it doesn't."):format(yd),
            wait = function()
                local d = state.npc and state.npc.id and spawnDistance(state.npc.id, true)
                if d and d >= yd - 4 and d <= yd + 6 then return true, d end
                return false, "now " .. fmt(d) .. " yd"
            end, timeout = 600,
        }
        def[#def + 1] = {
            text = ("Left-click the probe button (%d yd)."):format(yd),
            wait = function()
                n0 = n0 or state.clicks
                local done, target, plate, mark, d = clickedSince(n0)
                if done then n0 = nil end
                return done, target, plate, mark, d
            end, timeout = 300,
            check = function()
                local c = state.lastClick
                return c and c.target ~= nil and c.target == c.wanted, "targeted " .. str(c and c.target)
                    .. ", plate " .. tostring(c and c.plate)
            end,
        }
    end
    return def
end

Probe:Steps("range", rangeSteps({
    rev = 1,
    title = "Stakeout: how far /targetexact reaches (P5)",
    { text = "Stand next to the NPC you turn quests in to (or any NPC who stays put), target him, then press "
          .. "Read target. A probe button appears below the centre of the screen.", button = "Read target",
      run = function()
          local ok, name, id = readTarget("npc")
          if not ok then return false, "no name" end
          return aim(name, id, "8")
      end },
    { text = "Right-click the probe button twice (it marks him with a skull, /tm 8). Is the skull still on him "
          .. "after the second click?", ask = true },
    { text = "The right-click now uses /tm !8.", auto = true, run = function()
          return state.npc and aim(state.npc.name, state.npc.id, "!8")
      end },
    { text = "Right-click it twice again. Is the skull still on him after the second click?", ask = true },
    { text = "Clear your target (Escape).", event = "PLAYER_TARGET_CHANGED" },
}))

do
    local n0
    Probe:Steps("hostile", {
        rev = 1,
        title = "Stakeout: /targetexact on a mob without a nameplate (P5)",
        { text = "Go to the mobs one of your kill quests needs. Target one, then press Read target: the probe "
              .. "button now names it.", button = "Read target", run = function()
              local ok, name, id = readTarget("mob")
              if not ok then return false, "no name" end
              return aim(name, id, "8")
          end },
        { text = "Back away until none of them has a nameplate on screen (or press Shift+V to hide enemy "
              .. "nameplates). Clear your target, then left-click the probe button.",
          wait = function()
              n0 = n0 or state.clicks
              local done, target, plate = clickedSince(n0)
              if done then n0 = nil end
              return done, target, plate
          end, timeout = 600,
          check = function()
              local c = state.lastClick
              return c and c.target ~= nil and not c.plate, "targeted " .. str(c and c.target) .. ", plate "
                  .. tostring(c and c.plate)
          end },
        { text = "Did it target a mob you couldn't see a nameplate for? Type roughly how far it was in the note.",
          ask = true },
        { text = "Removing the probe button (out of combat).", button = "Remove", run = function() return buttonOff() end },
    })
end

-- Corpses: which unit /targetexact picks when dead and live ones share a name, and whether a macro line skips
-- the dead (the hostile run landed on a corpse). Each variant sets the left-click macro, then waits for a click.
do
    local VARIANTS = {
        { "A", "/cleartarget\n/targetexact <name>", "the macro quest buttons would use" },
        { "A again", "/cleartarget\n/targetexact <name>", "the same macro, a second time" },
        { "B", "/cleartarget\n/targetexact <name>\n/cleartarget [dead]", "drops a dead target" },
        { "C", "/cleartarget\n/targetexact <name>\n/cleartarget [dead]\n/targetexact <name>",
          "drops a dead target, then tries again" },
        { "D", "/cleartarget\n/target <name>", "/target instead of /targetexact" },
        { "E", "/targetexact <name>", "no /cleartarget: click it twice, does it move to another one?" },
        { "E again", "/targetexact <name>", "the second click" },
    }
    local n0
    local steps = {
        rev = 1,
        title = "Stakeout: /targetexact with corpses around",
        { text = "Go to a quest mob you can kill, where several of the same name are about. Kill one and stay "
              .. "by its corpse (looted or not); at least one live one should still be in view. Out of combat, "
              .. "target a live one, then press Read target.", button = "Read target", run = function()
              local ok, name, id = readTarget("mob")
              if not ok then return false, "no name" end
              state.corpseMob = { name = name, id = id }
              return true, name, id
          end },
    }
    for _, v in ipairs(VARIANTS) do
        local label, macro, what = v[1], v[2], v[3]
        steps[#steps + 1] = { text = "Variant " .. label .. " (" .. what .. "). Out of combat, press Set.",
            button = "Set", run = function()
                -- A throw keeps the step (Retry), so a failed Set never leads on to a click with no button
                local m = state.corpseMob
                if not m then error("no mob read yet: press Back to step 1", 0) end
                local ok, why = aim(m.name, m.id, "8", macro)
                if not ok then error(tostring(why) .. ": press Set again once out of combat", 0) end
                return true
            end }
        steps[#steps + 1] = { text = (label:find("again") and "" or "Clear your target (Escape). ")
                .. "Left-click the probe button once, then look: did it target the corpse or a live one?",
            wait = function()
                n0 = n0 or state.clicks
                local done, target, plate, _, _, dead, uid = clickedSince(n0)
                if done then n0 = nil end
                return done, target, plate, dead, uid
            end, timeout = 600 }
    end
    steps[#steps + 1] = { text = "Roughly how far was the nearest live one, and the corpse? Type it in the note, "
            .. "then answer: did any variant reach a live one while a corpse was closer?", ask = true }
    steps[#steps + 1] = { text = "Removing the probe button (out of combat).", button = "Remove",
        run = function() return buttonOff() end }
    Probe:Steps("corpse", steps)
end

-- Tagged mobs (#95): whether a button could aim at one nameplate (a live mob
-- nobody else tagged), and whether such an aim stays right. Five questions:
--   1 UnitIsTapDenied: plain or secret, on a mob someone else tagged, an
--     untagged one, one you tagged;
--   2 whether a secure macro targets a given plate: P1 /target nameplateN,
--     P2 /target [@nameplateN,exists,nodead];
--   3 whether an aimed button stays right: (a) the mob tagged by someone else
--     after the aim, (b) its plate lost in combat, when the button can't change;
--   4 how stable a plate token is (its GUID changing without a REMOVED);
--   5 whether /targetexact picks the nearer of two live mobs.
-- A click counts only on the edge the action runs on, and a trial is scored
-- only when what it needs is known; anything else is logged as inconclusive
-- and the step waits for another click. Designed with Codex over 13 rounds.
do
    local TG = { lock = 0, clicks = 0 }
    state.tagged = TG

    -- The secret check first: comparing a secret, even to nil, throws.
    local function plainGuid(unit)
        local ok, g = call(G("UnitGUID"), unit)
        if not ok then return nil, false end
        if secret(g) then return nil, true end
        return type(g) == "string" and g or nil, false
    end
    -- true / false, or "secret" / "missing".
    local function flag(fn, unit)
        local ok, v = call(G(fn), unit)
        if not ok then return "missing" end
        if secret(v) then return "secret" end
        return v == true
    end
    local function exists(unit) return flag("UnitExists", unit) == true end
    -- Whether a unit is there: true, false, or nil when that can't be read
    -- (an unreadable read is never a confirmed absence; Codex on #95's code).
    local function presence(unit)
        local f = flag("UnitExists", unit)
        if f == true or f == false then return f end
    end
    local function shortGuid(g) return g and (g:match("%-(%x+)$") or g) or "-" end

    -- The plates showing a live mob of the name: { token, guid, tap }.
    local function platesOf(name)
        local out = {}
        for i = 1, 40 do
            local token = "nameplate" .. i
            if exists(token) then
                local ok, n = call(G("UnitName"), token)
                if ok and text(n) == name then
                    local g = plainGuid(token)
                    out[#out + 1] = { token = token, guid = g, tap = flag("UnitIsTapDenied", token),
                                      dead = flag("UnitIsDead", token) }
                end
            end
        end
        return out
    end
    -- Range.lua's bracket, through Stakeout's test seam (Stakeout is optional).
    local function bracket(unit)
        local S = G("Stakeout")
        local R = type(S) == "table" and type(S._test) == "table" and S._test.range
        if type(R) ~= "table" or type(R.Get) ~= "function" then return nil, nil, "range unavailable" end
        local ok, low, high = pcall(R.Get, unit)
        if not ok or type(low) ~= "number" then return nil, nil, "no range" end
        return low, high
    end
    local function actsOnDown(btn)
        local fn = G("SecureActionButton_ShouldUseOnKeyDown")
        if fn then return fn(btn) and true or false end
        local cvar = G("GetCVarBool")
        return cvar ~= nil and cvar("ActionButtonUseKeyDown") and true or false
    end

    -- A lockdown counter: the plate lost and the click must share one. Every
    -- event on the aimed plate is logged with what the addon could read then.
    local lockFrame = CreateFrame("Frame")
    -- Registered once a trial starts, after the saved log is bound, so a
    -- refused event is in StakeoutProbeDB.log (Codex on #95's code).
    local function listen()
        if TG.listening then return end
        TG.listening = true
        -- Each false when one of its events was refused: the measurement that
        -- needs it (3b the fight's, 4 the plates') reports inconclusive.
        TG.combatOk = Probe:RegisterEvents(lockFrame, { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) ~= false
        TG.plateOk = Probe:RegisterEvents(lockFrame, { "NAME_PLATE_UNIT_REMOVED", "NAME_PLATE_UNIT_ADDED" }) ~= false
    end
    -- 3b: the aimed mob seen on its plate in this lockdown (the evidence a
    -- later loss happened in the fight, not before it). Only with lockdown
    -- read on: PLAYER_REGEN_DISABLED can come before it (porting guide).
    -- Seeing it back also retires an earlier loss.
    local function seeOriginal()
        local set = TG.set
        if set and set.purpose == "3b" and presence(set.token) and plainGuid(set.token) == set.guid then
            if set.lost then
                say("tagged: 3b the aimed mob is back on " .. set.token .. "; the earlier loss no longer stands")
                set.lost = nil
            end
            if inCombat() then set.seenLock = TG.lock end
        end
    end
    -- 3b's evidence, brought up to date: the sighting, then a change of the
    -- plate's mob. Run by each poll and on the click's own edge, so the click
    -- is judged by what was true when it happened (Codex on #95's code).
    local function track3b()
        local set = TG.set
        if not (set and set.purpose == "3b") then return end
        seeOriginal()
        local g = plainGuid(set.token)
        local here = presence(set.token)
        if not set.lost and here and g and g ~= set.guid then
            TG.lossN = (TG.lossN or 0) + 1
            set.lost = { id = TG.lossN, lock = TG.lock, combat = inCombat(),
                         afterSeen = inCombat() and set.seenLock == TG.lock, how = "now " .. shortGuid(g) }
            say(("tagged: %s now shows %s (lockdown %d, in combat %s)"):format(set.token, shortGuid(g), TG.lock,
                tostring(inCombat())))
        elseif not set.lost and here == false and inCombat() and set.seenLock == TG.lock then
            -- Seen in this fight, now confirmed gone: a loss even if its
            -- REMOVED never came (Codex on #95's code).
            TG.lossN = (TG.lossN or 0) + 1
            set.lost = { id = TG.lossN, lock = TG.lock, combat = true, afterSeen = true, how = "absent" }
            say(("tagged: %s is gone (lockdown %d)"):format(set.token, TG.lock))
        end
    end
    lockFrame:SetScript("OnEvent", function(_, event, token)
        if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            TG.lock = TG.lock + 1   -- a fight's start and its end each begin a new one
            if event == "PLAYER_REGEN_DISABLED" then
                seeOriginal()
                -- 4's window is out of combat only: a fight, even one between
                -- two polls, starts it again (Codex on #95's code).
                if TG.stab and TG.onFight then TG.onFight() end
            end
        elseif TG.set and token == TG.set.token then
            local set = TG.set
            local g, gs = plainGuid(token)
            say(("tagged: %s %s, now %s, tapped %s (lockdown %d, in combat %s)"):format(token,
                event == "NAME_PLATE_UNIT_ADDED" and "added" or "removed", gs and "unreadable" or shortGuid(g),
                tostring(flag("UnitIsTapDenied", token)), TG.lock, tostring(inCombat())))
            if event == "NAME_PLATE_UNIT_REMOVED" and not set.lost then
                TG.lossN = (TG.lossN or 0) + 1
                set.lost = { id = TG.lossN, lock = TG.lock, combat = inCombat(), afterSeen = set.seenLock == TG.lock,
                             how = "removed" }
            elseif event == "NAME_PLATE_UNIT_ADDED" then
                seeOriginal()
            end
        end
        if TG.watchTokens and (event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED") then
            TG.onPlateEvent(event, token)
        end
    end)

    -- The click, on the action's edge only (left button).
    local function onTagClick(btn, which, down)
        -- Only a click of the macro the trial set (anything else re-aimed the
        -- button since): never logged under a trial it isn't.
        if not TG.set or TG.set.gen ~= state.aimGen or which ~= "LeftButton" then return end
        if (down and true or false) ~= actsOnDown(btn) then return end
        local set = TG.set
        TG.clicks = TG.clicks + 1
        track3b()
        -- A copy: a later poll may retire or replace the set's loss.
        local lostNow = set.lost and { id = set.lost.id, lock = set.lost.lock, combat = set.lost.combat,
                                       afterSeen = set.lost.afterSeen }
        -- A false read stays false: no `x and false or y` here. "none" and
        -- "absent" are confirmed; anything that can't be read is "unreadable".
        local c = { n = TG.clicks, set = set, lock = TG.lock, combat = inCombat(), target = "unreadable",
                    token = "unreadable", dead = "unreadable", tap = "unreadable", lost = lostNow }
        local hasTarget = presence("target")
        if hasTarget == false then
            c.target = "none"
        elseif hasTarget then
            c.target = plainGuid("target") or "unreadable"
            c.targetTap = flag("UnitIsTapDenied", "target")
        end
        local here = presence(set.token)
        if here == false then
            c.token, c.dead, c.tap = "absent", "absent", "absent"
        elseif here then
            c.token = plainGuid(set.token) or "unreadable"
            c.dead = flag("UnitIsDead", set.token)
            c.tap = flag("UnitIsTapDenied", set.token)
        end
        -- 5: both mobs of the pair as they are at this click, read on its edge
        -- (a poll a second later could see them moved; Codex on #95's code).
        local N = TG.near
        if N and N.pair then
            c.near, c.pairId = {}, N.pairId
            for k, m in ipairs(N.pair) do
                local s = { guid = m.guid, token = m.token, dead = "absent" }
                if presence(m.token) and plainGuid(m.token) == m.guid then
                    s.dead = flag("UnitIsDead", m.token)
                    s.low, s.high = bracket(m.token)
                end
                c.near[k] = s
            end
        end
        TG.click = c
        -- Every click is kept, in order: two before a poll are both judged
        -- (Codex on #95's code). The last few only.
        TG.queue = TG.queue or {}
        TG.queue[#TG.queue + 1] = c
        if #TG.queue > 20 then table.remove(TG.queue, 1) end
        say(("tagged click %d [%s]: target %s (tapped %s), %s now %s (dead %s, tapped %s), lockdown %d, in combat %s")
            :format(c.n, set.variant, shortGuid(c.target), tostring(c.targetTap), set.token, shortGuid(c.token),
            tostring(c.dead), tostring(c.tap), c.lock, tostring(c.combat)))
    end
    local function hook()
        if TG.hooked or not button then return end
        button:HookScript("PostClick", onTagClick)
        TG.hooked = true
    end

    local VARIANTS = {
        P1 = "/cleartarget\n/target %s",
        P2 = "/cleartarget\n/target [@%s,exists,nodead]",
    }
    -- Aims the button at a plate of the name: a live mob, not the target, its
    -- GUID known. Out of combat. Throws, so a Set that failed stays (Retry).
    -- purpose: the measurement this Set is for ("2", "3a", "3b"); each wait
    -- scores only a click of its own Set (Codex on #95's code).
    -- wantTap: false (untagged only), nil (any live one) or "prefer" (an
    -- untagged one when there is one, else any).
    local function setOn(variant, wantTap, purpose)
        local name = state.tagMob and state.tagMob.name
        if not name then error("no mob read yet: go Back to the first step", 0) end
        if inCombat() then error("in combat: Set again once out of it", 0) end
        listen()
        -- A target there but not readable could be the mob picked below: the
        -- control would prove nothing (Codex on #95's code).
        local tgt, tgtSecret = plainGuid("target")
        if presence("target") ~= false and not tgt then
            error("your target can't be read: clear it (Esc), then Set again", 0)
        end
        local function pickWith(tap)
            for _, p in ipairs(platesOf(name)) do
                if p.guid and p.guid ~= tgt and p.dead == false and (tap == nil or p.tap == tap) then return p end
            end
        end
        local pick
        if wantTap == "prefer" then
            pick = pickWith(false) or pickWith(nil)
        else
            pick = pickWith(wantTap)
        end
        if not pick then
            error(("no plate of %s to aim at (live, not your target%s): move closer, Set again"):format(name,
                wantTap == false and ", untagged" or ""), 0)
        end
        local ok, why = aim(name, state.tagMob.id, "8", VARIANTS[variant]:format(pick.token))
        if not ok then error(tostring(why), 0) end
        hook()
        TG.set = { variant = variant, purpose = purpose or "2", token = pick.token, guid = pick.guid, tap = pick.tap,
                   lock = TG.lock, combat = inCombat(), gen = state.aimGen }
        TG.tagSeen, TG.seen = false, TG.clicks
        -- A new Set for 2 replaces that variant's result.
        if TG.set.purpose == "2" and TG.passed then TG.passed[variant] = nil end
        say(("tagged: %s for %s aimed at %s = %s (tapped %s); the target before: %s"):format(variant,
            TG.set.purpose, pick.token, shortGuid(pick.guid), tostring(pick.tap),
            tgtSecret and "unreadable" or (tgt and shortGuid(tgt) or "none")))
        return true, variant, pick.token, shortGuid(pick.guid)
    end
    -- The wait's own Set, or nil: its purpose, its variant, and still the
    -- button's macro (anything re-aiming the button ends it).
    local function setFor(purpose, variant)
        local set = TG.set
        if set and set.purpose == purpose and (variant == nil or set.variant == variant)
            and set.gen == state.aimGen then return set end
    end

    -- A new click since the last Set (setOn resets TG.seen), or nil: a click
    -- of an older Set is never a new one.
    -- The oldest click not judged yet.
    local function newClick()
        for _, c in ipairs(TG.queue or {}) do
            if c.n > (TG.seen or 0) then
                TG.seen = c.n
                return c
            end
        end
    end

    -- Measurement 2: scored when the token still shows the Set-time GUID and
    -- the mob is alive; else the button is aimed again and it waits.
    local function plateTrial(variant)
        return function()
            local set = setFor("2", variant)
            if not set then return false, "press Back and Set " .. variant .. " first" end
            local c = newClick()
            if not c then return false, "left-click the probe button" end
            if c.token ~= set.guid or c.dead ~= false then
                local why = c.token ~= set.guid and ("the plate now shows " .. shortGuid(c.token)) or "the mob is dead"
                say("tagged: " .. variant .. " inconclusive, " .. why .. "; aiming again")
                local ok, err = pcall(setOn, variant, "prefer", "2")
                return false, ok and ("inconclusive (" .. why .. "): click again") or tostring(err)
            end
            if c.target == "unreadable" then
                say("tagged: " .. variant .. " inconclusive, the target's GUID is unreadable")
                return false, "inconclusive (the target's GUID can't be read): click again"
            end
            local hit = c.target == set.guid
            -- Carried forward to 3 only from a live, untagged mob at Set and at
            -- the click: a tagged one says nothing about the control.
            local control = set.tap == false and c.tap == false
            TG.passed = TG.passed or {}
            TG.passed[variant] = (hit and control) or nil   -- this result replaces any earlier one
            TG.scored = variant   -- this visit of the wait ended on a click (keepPass)
            local result = hit and "targeted the plate's mob" or (c.target == "none" and "no target")
                or ("targeted another (" .. shortGuid(c.target) .. ")")
            say(("tagged: %s scored: %s%s"):format(variant, result,
                (hit and not control) and " (the mob was tagged: not carried forward)" or ""))
            return true, variant, result
        end
    end
    -- The 2 wait's leave: a result stands only if this visit scored it. Done
    -- by hand (after a Back) replaces the saved result without a click, so
    -- the earlier pass goes too (Codex on #95's code).
    local function keepPass(variant)
        return function(outcome)
            if TG.scored ~= variant and TG.passed then TG.passed[variant] = nil end
            TG.scored = nil
            -- Stopped: no aim stays live to log a reused token afterwards.
            if outcome == "stopped" then TG.set = nil end
        end
    end
    local function stopAim(outcome)
        if outcome == "stopped" then TG.set = nil end
    end
    local function chosen()
        return TG.passed and (TG.passed.P1 and "P1" or TG.passed.P2 and "P2") or nil
    end

    -- 3(a): the change seen on the Set-time mob itself, false -> true.
    local function tagWait()
        local set = setFor("3a")
        if not set then return false, "press Back and Set first" end
        if TG.tagSeen then return true, "tag seen" end
        local g = plainGuid(set.token)
        local tap = flag("UnitIsTapDenied", set.token)
        if set.tap == false and g == set.guid and tap == true then
            TG.tagSeen = true
            TG.seen = TG.clicks   -- only a click after the tag counts
            say(("tagged: %s (%s) became tapped while aimed (lockdown %d, in combat %s)"):format(set.token,
                shortGuid(g), TG.lock, tostring(inCombat())))
            return true, "tagged by someone else, seen on " .. set.token
        end
        return false, ("waiting for %s (%s) to be tagged by someone else"):format(set.token, shortGuid(set.guid))
    end
    local function tagClick()
        local set = setFor("3a")
        if not set then
            say("tagged: 3a no Set for it, inconclusive")
            return true, "no Set for it, inconclusive"
        end
        local c = newClick()
        if not c then return false, "left-click the probe button" end
        if not TG.tagSeen then
            say("tagged: 3a no observed tag, inconclusive")
            return true, "no observed tag, inconclusive"
        end
        if c.token ~= set.guid or c.dead ~= false or c.tap ~= true then
            say(("tagged: 3a not scored (token %s, dead %s, tapped %s)"):format(shortGuid(c.token),
                tostring(c.dead), tostring(c.tap)))
            return true, "not scored: the mob changed, died or isn't tapped any more"
        end
        if c.target == "unreadable" then
            say("tagged: 3a inconclusive, the target can't be read")
            return true, "inconclusive: the target can't be read"
        end
        local result = c.target == set.guid and "targeted the tagged mob" or (c.target == "none" and "no target")
            or ("targeted " .. shortGuid(c.target))
        say("tagged: 3a scored: " .. result)
        return true, "scored", result
    end

    -- 3(b): the plate lost and the click in one uninterrupted lockdown.
    local function lostWait()
        local set = setFor("3b")
        if not set then return false, "press Back and Set first" end
        -- Without the fight's events the lockdowns can't be told apart.
        if TG.combatOk == false then
            say("tagged: 3b inconclusive, the combat events couldn't be registered")
            return true, "inconclusive: the combat events couldn't be registered (see the log)"
        end
        -- A loss counts only if the aimed mob was seen on its plate in this
        -- same lockdown first (a poll or a plate event in it): a change seen
        -- before the fight keeps its own lockdown and never becomes an
        -- in-fight loss. The click is judged by the evidence on its own edge
        -- (c.lost), not by the plate's state at this poll (Codex on #95's code).
        track3b()
        local c = newClick()
        if not c then
            if set.lost then return false, "the plate is gone: left-click the probe button, still in combat" end
            return false, "pull something; in combat, move until the aimed mob's plate goes"
        end
        local lost = c.lost
        if not lost then
            say("tagged: 3b unchanged, inconclusive")
            return false, "unchanged, inconclusive: lose the plate first, then click"
        end
        if not (lost.combat and lost.afterSeen and c.combat and lost.lock == c.lock) then
            say("tagged: 3b inconclusive: the loss and the click weren't in one fight with the mob seen in it first")
            -- Only that loss goes: a newer one seen since the click stays.
            if set.lost and set.lost.id == lost.id then set.lost = nil end
            return false, "inconclusive (not one fight): get the aimed mob's plate back, then try again"
        end
        -- (The aimed mob back on its plate at the click retired the loss on
        -- the click's edge, so such a click is "unchanged" above.)
        if c.token == "unreadable" or c.target == "unreadable" then
            say("tagged: 3b inconclusive, the plate or the target can't be read")
            return false, "inconclusive (can't be read): click again"
        end
        local plate = c.token == "absent" and "absent" or ("another mob, " .. shortGuid(c.token))
        local result = c.target == "none" and "no target"
            or (c.target == set.guid and "the aimed mob") or ("a target, " .. shortGuid(c.target))
        say(("tagged: 3b scored: token %s, click gave %s"):format(plate, result))
        return true, plate, result
    end

    -- 4: every plate's GUID, four times a second, for two minutes.
    local ticker
    local stopStability
    local function stability()
        listen()
        -- Two minutes out of combat: a fight (3b ends in one) restarts them.
        if inCombat() then
            if TG.stab then
                say("tagged: 4 in combat: the two minutes start again once you're out")
                stopStability()
            end
            return false, "leave combat: the two minutes start once you're out"
        end
        if not TG.stab then
            TG.stab = { from = (G("GetTime") or function() return 0 end)(), guids = {}, silent = 0,
                        adds = 0, removes = 0, compared = 0 }
            TG.watchTokens = true
            -- A REMOVED forgets the token's GUID, so the next mob on it is a
            -- fresh one; only a change with no REMOVED in between counts.
            TG.onPlateEvent = function(event, token)
                local s = TG.stab
                if not s then return end
                local g, gs = plainGuid(token)
                if event == "NAME_PLATE_UNIT_REMOVED" then
                    s.removes = s.removes + 1
                    s.guids[token] = nil
                else
                    s.adds = s.adds + 1
                    -- An ADDED on a token still holding another mob, with no
                    -- REMOVED between: that's a silent change too. Then what it
                    -- shows is the baseline for the next poll (Codex on #95's code).
                    local was = s.guids[token]
                    if g and was then s.compared = s.compared + 1 end
                    if g and was and g ~= was then
                        s.silent = s.silent + 1
                        say(("tagged: 4 %s added as %s while it held %s, with no REMOVED"):format(token,
                            shortGuid(g), shortGuid(was)))
                    end
                    if g then s.guids[token] = g end
                end
                say(("tagged: 4 %s %s %s tapped %s"):format(token, event == "NAME_PLATE_UNIT_ADDED" and "added" or "removed",
                    gs and "unreadable" or shortGuid(g), tostring(flag("UnitIsTapDenied", token))))
            end
            ticker = ticker or CreateFrame("Frame")
            ticker.t = 0
            ticker:SetScript("OnUpdate", function(f, e)
                f.t = f.t + (e or 0)
                if f.t < 0.25 then return end
                f.t = 0
                TG.stabPoll()
            end)
            TG.stabPoll = function()
                local s = TG.stab
                if not s then return end
                for i = 1, 40 do
                    local token = "nameplate" .. i
                    local g = exists(token) and plainGuid(token) or nil
                    local was = s.guids[token]
                    if g and was then s.compared = s.compared + 1 end
                    if g and was and g ~= was then
                        s.silent = s.silent + 1
                        say(("tagged: 4 %s changed %s -> %s with no REMOVED"):format(token, shortGuid(was), shortGuid(g)))
                    end
                    if g then s.guids[token] = g end
                end
            end
        end
        local s = TG.stab
        local left = 120 - ((G("GetTime") or function() return 0 end)() - s.from)
        if left > 0 then return false, ("%d s left; stay near several mobs"):format(left) end
        if TG.plateOk == false then
            return true, "inconclusive: a plate event couldn't be registered (see the log)"
        end
        -- Without the fight's events a fight between polls can't restart the
        -- window, so "out of combat" isn't known (Codex on #95's code).
        if TG.combatOk == false then
            return true, "inconclusive: the combat events couldn't be registered (see the log)"
        end
        -- Nothing seen twice: nothing to compare, not "no changes".
        if s.compared == 0 then
            return true, "inconclusive: no plate was seen long enough to compare"
        end
        return true, ("adds %d, removes %d, GUID changes with no REMOVED %d (%d comparisons)"):format(s.adds,
            s.removes, s.silent, s.compared)
    end
    stopStability = function()
        if ticker then ticker:SetScript("OnUpdate", nil) end
        TG.stab, TG.watchTokens = nil, nil
    end
    TG.onFight = function()
        say("tagged: 4 a fight began: the two minutes start again once you're out")
        stopStability()
    end

    -- 5: two live mobs at clearly different distances; each scored click
    -- needs the other one nearer than at the last one.
    local function disjoint(a, b)
        if not (a.low and b.low) then return nil end
        if a.high <= b.low then return a end
        if b.high <= a.low then return b end
    end
    local function rangeReachable()
        local S = G("Stakeout")
        local R = type(S) == "table" and type(S._test) == "table" and S._test.range
        return type(R) == "table" and type(R.Get) == "function"
    end
    local function nearestTrial()
        -- Moving can't help without Range.lua: say so and end (Codex on #95's code).
        if not rangeReachable() then
            say("tagged: 5 inconclusive, Range.lua isn't reachable (Stakeout not loaded)")
            return true, "range unavailable (is Stakeout loaded?): inconclusive"
        end
        if not setFor("5") then return false, "press Back and Set first" end
        local name = state.tagMob and state.tagMob.name
        local N = TG.near
        if not N then
            N = { scored = {}, pairId = 0 }
            TG.near = N
            TG.seen = TG.clicks
        end
        -- A pending click first, against the pair it was made on: losing the
        -- pair after it must not throw it away (Codex on #95's code).
        local c = newClick()
        while c and N.pair and c.pairId == N.pairId do
            local done, msg = TG.scoreNear(N, c)
            if done then return true, msg end
            N.pendingMsg = msg
            c = newClick()
        end
        -- The pair: chosen, or lost and chosen again. Each keeps its plate:
        -- a mob moved to another token isn't the same observation.
        if N.pair then
            for _, m in ipairs(N.pair) do
                -- Gone from its plate, or dead on it: no use for the trial.
                if not (presence(m.token) and plainGuid(m.token) == m.guid) or flag("UnitIsDead", m.token) == true then
                    say("tagged: 5 lost the pair; choosing again")
                    N.pair, N.scored, N.last, N.pendingMsg = nil, {}, nil, nil
                    break
                end
            end
        end
        if not N.pair then
            local live = {}
            for _, p in ipairs(platesOf(name)) do
                if p.guid and p.dead == false then
                    local low, high = bracket(p.token)
                    if low then live[#live + 1] = { guid = p.guid, token = p.token, low = low, high = high } end
                end
            end
            for i = 1, #live do
                for j = i + 1, #live do
                    if not N.pair and disjoint(live[i], live[j]) then N.pair = { live[i], live[j] } end
                end
            end
            if not N.pair then return false, "waiting for two live " .. tostring(name) .. " at clearly different distances" end
            -- A click is scored only against the pair chosen before it.
            N.pairId = N.pairId + 1
            say(("tagged: 5 pair %d: %s and %s"):format(N.pairId, shortGuid(N.pair[1].guid), shortGuid(N.pair[2].guid)))
        end
        if c then
            say("tagged: 5 click not scored (it came before this pair was chosen)")
            return false, "not scored: click again"
        end
        if N.pendingMsg then
            local msg = N.pendingMsg
            N.pendingMsg = nil
            return false, msg
        end
        return false, ("%d of 4 scored: left-click the probe button%s"):format(#N.scored,
            N.last and (" once " .. shortGuid(N.last) .. " is the farther one") or "")
    end
    -- One click against its own pair, as its edge read them: both on their
    -- plates, alive, apart. Returns done, and what to show.
    TG.scoreNear = function(N, c)
        local now = c.near
        local near = (now[1].dead == false and now[2].dead == false) and disjoint(now[1], now[2]) or nil
        if not near then
            say("tagged: 5 click not scored (a mob dead, gone or the distances overlap)")
            return false, "not scored: both alive and clearly apart, then click again"
        end
        local far = near == now[1] and now[2] or now[1]
        if N.last and near.guid == N.last then
            say("tagged: 5 click not scored: the same one is still the nearer")
            return false, "not scored: move until the other one is nearer, then click"
        end
        local picked = c.target == near.guid and "the nearer"
            or ((c.target == now[1].guid or c.target == now[2].guid) and "the farther")
            or "another (inconclusive)"
        if picked:find("inconclusive") then
            local what = c.target == "none" and "no target" or (c.target == "unreadable" and "a target that can't be read")
                or ("a third mob, " .. shortGuid(c.target))
            say("tagged: 5 not scored, the click gave " .. what)
            return false, "not scored (" .. what .. "): click again"
        end
        N.scored[#N.scored + 1] = picked
        N.last = near.guid
        say(("tagged: 5 scored %d: picked %s (nearer %s at %s-%s yd, farther %s at %s-%s yd)"):format(#N.scored,
            picked, shortGuid(near.guid), tostring(near.low), tostring(near.high), shortGuid(far.guid),
            tostring(far.low), tostring(far.high)))
        if #N.scored < 4 then return false, ("%d of 4 scored: now move until the other one is nearer"):format(#N.scored) end
        return true, table.concat(N.scored, ", ")
    end

    local function readTap(what)
        return function()
            if not exists("target") then error("no target: target " .. what .. ", then Read", 0) end
            local tap = flag("UnitIsTapDenied", "target")
            local g = plainGuid("target")
            local all = {}
            for _, p in ipairs(platesOf(state.tagMob and state.tagMob.name or "")) do
                all[#all + 1] = ("%s %s tapped %s"):format(p.token, shortGuid(p.guid), tostring(p.tap))
            end
            say(("tagged: 1 %s: UnitIsTapDenied %s, dead %s, %s; plates: %s"):format(what, tostring(tap),
                tostring(flag("UnitIsDead", "target")), shortGuid(g), #all > 0 and table.concat(all, "; ") or "none"))
            return tap ~= "missing", what, tostring(tap)
        end
    end

    -- A Set step for one measurement. Skipping it (or going Back past it)
    -- drops the aim, so its wait never scores a click of an older Set.
    local function setStep(variant, purpose, text, wantTap)
        return { text = text, button = "Set", run = function()
            if variant == "chosen" then
                local v = chosen()
                if not v then error("no macro targeted a live, untagged plate's mob in step 2: Skip this part", 0) end
                return setOn(v, wantTap, purpose)
            end
            return setOn(variant, wantTap, purpose)
        end, leave = function(outcome)
            if outcome == "skipped" or outcome == "back" or outcome == "stopped" then TG.set = nil end
        end }
    end

    -- buttonOff refuses in combat with a plain return; the throw keeps the
    -- step (Remove again), so the button is never left up (Codex on the plan).
    local function cleanup()
        local ok, why = buttonOff()
        if not ok then error(tostring(why) .. ": press Remove again once out of combat", 0) end
        TG.set = nil
        return true
    end

    -- The first step: a fresh run, then the mob. A failed read throws, so the
    -- step stays (Retry) and no earlier run's mob carries on (Codex on #95's code).
    local function resetRun()
        state.tagMob, TG.passed, TG.near, TG.set, TG.tagSeen = nil, nil, nil, nil, false
    end
    local function readMob()
        resetRun()
        local ok, name, id = readTarget("mob")
        -- The name read here too: readTarget's can be an error's text when
        -- UnitName throws (Codex on #95's code).
        local okN, n = call(G("UnitName"), "target")
        if not ok or not okN or text(n) == nil or text(n) ~= name then
            error("no mob read: target one of them, then Read target again", 0)
        end
        state.tagMob = { name = name, id = id }
        return true, name, id
    end
    -- Step 5's Set: the plain macro, as its own aim.
    local function setNearest()
        local m = state.tagMob
        if not m then error("no mob read yet: go Back to the first step", 0) end
        if inCombat() then error("in combat: Set again once out of it", 0) end
        listen()
        local ok, why = aim(m.name, m.id, "8", "/cleartarget\n/targetexact <name>")
        if not ok then error(tostring(why), 0) end
        hook()
        TG.set = { variant = "targetexact", purpose = "5", token = "target", gen = state.aimGen }
        TG.near = nil
        return true
    end
    local function dropSet(outcome)
        if outcome == "skipped" or outcome == "back" or outcome == "stopped" then TG.set = nil end
    end
    -- Back from 3a's click to its tag wait: the earlier sighting no longer
    -- stands, so a Done by hand there can't reuse it (Codex on #95's code).
    local function forgetTag(outcome)
        if outcome == "back" then TG.tagSeen = false end
        stopAim(outcome)
    end

    TG.api = { setOn = setOn, onTagClick = onTagClick, plateTrial = plateTrial, tagWait = tagWait,
               tagClick = tagClick, lostWait = lostWait, nearestTrial = nearestTrial, stability = stability,
               stopStability = stopStability, chosen = chosen, readTap = readTap, cleanup = cleanup,
               setStep = setStep, readMob = readMob, setNearest = setNearest, dropSet = dropSet,
               resetRun = resetRun, forgetTag = forgetTag, keepPass = keepPass, stopAim = stopAim }

    Probe:Steps("tagged", {
        rev = 1,
        title = "Stakeout: tagged mobs and aiming at one nameplate (#95)",
        { text = "Go where several mobs of one quest name are about, with other players around if you can. Out of "
              .. "combat, target one of those mobs, then press Read target.", button = "Read target", run = readMob,
          -- Skipped, a run starts with nothing from the last one.
          leave = function(outcome) if outcome == "skipped" then resetRun() end end },
        -- 1
        { text = "Target one of them that ANOTHER player has tagged (its name or health bar is grey), then press "
              .. "Read. None about? Skip.", button = "Read", run = readTap("a mob someone else tagged") },
        { text = "Target one nobody has touched, then press Read.", button = "Read", run = readTap("an untagged mob") },
        { text = "Hit one yourself (tag it) and, while it's alive and targeted, press Read. Then finish it and leave "
              .. "combat.", button = "Read", run = readTap("a mob you tagged") },
        -- 2
        setStep("P1", "2", "Out of combat, target something else (or nothing). Press Set: the probe button targets "
              .. "one plate of that name, an untagged mob if there is one (/target nameplateN).", "prefer"),
        { text = "Left-click the probe button once. (If the probe says to, click again.)", wait = plateTrial("P1"),
          timeout = 600, leave = keepPass("P1") },
        setStep("P2", "2", "Out of combat again, target something else. Press Set: the same, as /target "
              .. "[@nameplateN,exists,nodead].", "prefer"),
        { text = "Left-click the probe button once. (If the probe says to, click again.)", wait = plateTrial("P2"),
          timeout = 600, leave = keepPass("P2") },
        -- 3a
        setStep("chosen", "3a", "Next: an aimed mob tagged by someone else. You need another player, or your "
              .. "other account, to hit the mob the probe picks. Press Set (it picks an untagged one), or Skip this "
              .. "part and the next two.", false),
        { text = "Have the other player hit the aimed mob now (the probe names its plate). Wait here.",
          wait = tagWait, timeout = 600, leave = stopAim },
        { text = "Left-click the probe button once, while the mob is alive.", wait = tagClick, timeout = 600,
          leave = forgetTag },
        -- 3b
        setStep("chosen", "3b", "Next: the aimed mob's plate lost in a fight. Out of combat, press Set."),
        { text = "Pull a different mob. During the fight, move until the aimed mob's plate goes away, then "
              .. "left-click the probe button, still in combat.", wait = lostWait, timeout = 900, leave = stopAim },
        -- 4
        { text = "Out of combat, stay near several mobs (walking around is fine) for two minutes.",
          -- No timeout: a fight restarts the window, which a fixed one would cut short.
          wait = stability, leave = stopStability },
        -- 5
        { text = "Out of combat, press Set: the probe button gets the plain /targetexact macro.", button = "Set",
          run = setNearest, leave = dropSet },
        { text = "Stand so that two live ones are at clearly different distances (one near, one far). Click the "
              .. "probe button; then move until the other one is the nearer and click again; four times in all.",
          wait = nearestTrial, timeout = 1200, leave = stopAim },
        { text = "Removing the probe button (out of combat).", button = "Remove", run = cleanup },
    })
end

Probe:Steps("events", {
    rev = 1,
    title = "Stakeout: quest event order (P6)",
    { text = "Logging quest events and objective changes.", auto = true, run = function() return events(true) end },
    { text = "Kill a mob one of your quests needs, then press Next." },
    { text = "Loot an item one of your quests needs (Skip if you have none), then press Next." },
    { text = "Turn in a quest at its NPC (Skip if none is ready), then press Next." },
    { text = "Accept a new quest (Skip if none is offered), then press Next." },
    { text = "Stopping the log.", auto = true, run = function() return events(false) end },
})

Probe:Steps("core", {
    rev = 1,
    title = "Stakeout: the watch list's buttons on this build (P8)",
    { text = "Stakeout must be enabled. Type /stakeout add <a nearby mob's name> (one you can kill), then press Next." },
    { text = "When its button shows in Stakeout's frame, left-click it. Did it target the mob?", ask = true },
    { text = "Right-click it. Did it mark the mob?", ask = true },
    { text = "Kill it. The step completes when something dies nearby.", event = "UNIT_DIED" },
    { text = "Did its button go away (if two had that name, once both were dead)?", ask = true },
    { text = "Type /stakeout remove <its name>, then press Next." },
})

Probe:Steps("mulgore", {
    rev = 1,
    title = "Stakeout: QuestieDB coordinates in a re-projected zone (P3)",
    { text = "Go to Mulgore (Bloodhoof Village, for instance). Stand right next to an NPC who stays put, target him, "
          .. "then press Read target.", button = "Read target", run = function() return readTarget("mulgore1") end,
      check = function()
          local id = state.mulgore1 and state.mulgore1.id
          local d, era = nil, nil
          if id then d, era = spawnDistance(id, true) end
          return d ~= nil and d <= 10, "as stored " .. fmt(d) .. " yd, as Era-converted " .. fmt(era) .. " yd"
      end },
    { text = "Another NPC there, far from the first: stand next to him, target him, then press Read target.",
      button = "Read target", run = function() return readTarget("mulgore2") end,
      check = function()
          local id = state.mulgore2 and state.mulgore2.id
          local d, era = nil, nil
          if id then d, era = spawnDistance(id, true) end
          return d ~= nil and d <= 10, "as stored " .. fmt(d) .. " yd, as Era-converted " .. fmt(era) .. " yd"
      end },
})

-- The look (#28): both looks over a bright and a dark scene, with the config
-- and export windows open beside the target frame. Each look is worn after a
-- /reload, so the owner switches with /stakeout look and the Reload step.
local function showLook()
    local S = G("Stakeout")
    local T = type(S) == "table" and S._test
    if type(T) ~= "table" or type(T.look) ~= "function" then error("Stakeout (with the look) isn't loaded", 0) end
    local cfg = G("StakeoutConfigFrame")
    if not (cfg and cfg:IsShown()) then T.CreateConfigFrame() end
    T.ShowExport()
    local f = T.frame()
    local look, shown = T.look(), f and f:IsShown() or false
    say(("look: %s; target frame %s"):format(look, shown and "shown" or "hidden (no button)"))
    return look, shown
end

local function wearing(look)
    return function()
        local S = G("Stakeout")
        local now = type(S) == "table" and S._test and S._test.look and S._test.look()
        return now == look, "wearing " .. tostring(now)
    end
end

Probe:Steps("look", {
    rev = 1,
    title = "Stakeout: the WoW Forever and Glass looks, bright and dark (#28)",
    { text = "Stand outdoors somewhere bright (sunlit grass, sand or snow) with a mob in view. Type "
          .. "/stakeout add <its name> and wait for its button, then press Next." },
    { text = "Type /stakeout look forever, then reload.", reload = true },
    { text = "WoW Forever, bright: opening the config and export windows.", auto = true, run = showLook,
      check = wearing("forever"), screenshot = "forever-bright" },
    { text = "WoW Forever, bright: is every label in the three windows easy to read?", ask = true },
    { text = "Type /stakeout look glass, then reload.", reload = true },
    { text = "Glass, bright: opening the config and export windows.", auto = true, run = showLook,
      check = wearing("glass"), screenshot = "glass-bright" },
    { text = "Glass, bright: is every label in the three windows easy to read?", ask = true },
    { text = "Left-click the mob's button, then right-click it. Did it target the mob, then mark it?", ask = true },
    { text = "Go somewhere dark (inside a building, a cave, or outdoors at night), then press Next." },
    { text = "Glass, dark: opening the windows again.", auto = true, run = showLook,
      check = wearing("glass"), screenshot = "glass-dark" },
    { text = "Glass, dark: is every label easy to read?", ask = true },
    { text = "Type /stakeout look forever, then reload.", reload = true },
    { text = "WoW Forever, dark: opening the windows again.", auto = true, run = showLook,
      check = wearing("forever"), screenshot = "forever-dark" },
    { text = "WoW Forever, dark: is every label easy to read?", ask = true },
    { text = "Overall, do you prefer Glass? (No: WoW Forever.) The Note box takes what you'd change.", ask = true },
    { text = "Type /stakeout remove <the mob's name>, and /stakeout look glass if you want to keep Glass. "
          .. "Then press Finish and /reload." },
})

--------------------------------------------------------------------------------
-- Boot: the saved log, and the login samples (P6)
--------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD" })
boot:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        Probe:Ready()
        if type(StakeoutProbeDB) ~= "table" then StakeoutProbeDB = {} end
        if type(StakeoutProbeDB.log) ~= "table" then StakeoutProbeDB.log = {} end
        Probe:UseLog(StakeoutProbeDB.log, MAX_LOG)
        StakeoutProbeDB.loads = (StakeoutProbeDB.loads or 0) + 1
        say("loaded (" .. StakeoutProbeDB.loads .. " loads). /fp so for the commands")
        sample("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        sample("PLAYER_LOGIN")
        local qa = G("Questie")
        local register = type(qa) == "table" and type(qa.API) == "table" and qa.API.RegisterOnReady
        if type(register) == "function" then
            local ok, err = pcall(register, function() sample("Questie ready") end)
            if not ok then say("Questie.API.RegisterOnReady: ERROR " .. str(err)) end
        end
    else
        sample("PLAYER_ENTERING_WORLD")
        local after = api("C_Timer", "After")
        if after then after(5, function() sample("+5 s") end) end
    end
end)

NS._test = { Probe = Probe, state = state, parseAreaMap = parseAreaMap, yards = yards, aim = aim,
             npcIdFromGuid = npcIdFromGuid }
