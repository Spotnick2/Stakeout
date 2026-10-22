------------------------------------------------------------
-- test_quests_frame.lua - which quest targets get a button and what it does
-- (#24, phase 2): tiers, the reserved turn-in slot, the cap of eight,
-- fairness over objectives, stable slots, the exact macros and markers, the
-- events and their coalesced rebuild, and the combat contract.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T, ns = WoW.loadAddon({ savedDB = { questTargets = true } })
local Q = ns.quests
local QT = Q._test
WoW.flushTimers()

local data = { objectives = {}, droppers = {}, names = {}, finishedBy = {} }
ns.questData = {
    Objectives = function(id) return data.objectives[id] end,
    ItemDroppers = function(id) return data.droppers[id] end,
    NpcName = function(id) return data.names[id] end,
    FinishedBy = function(id) return data.finishedBy[id] end,
}

local function row(type, text, finished) return { type = type, text = text, finished = finished or false } end
local function guid(id) return string.format("Creature-0-1-2-3-%d-A", id) end
local plates = 0
local function see(name, id, attackable)
    plates = plates + 1
    local token = "nameplate" .. plates
    WoW.SetUnit(token, { name = name, guid = guid(id), plate = true, attackable = attackable ~= false })
    WoW.fire("NAME_PLATE_UNIT_ADDED", token)
    return token
end
local function gone(token)
    WoW.units[token] = nil
    WoW.fire("NAME_PLATE_UNIT_REMOVED", token)
end
local function order()
    local out = {}
    for _, b in ipairs(T.buttons) do if b.shown then out[#out + 1] = b.npcName end end
    return table.concat(out, ",")
end
local function count() local n = 0 for _, b in ipairs(T.buttons) do if b.shown then n = n + 1 end end return n end
local function button(name)
    for _, b in ipairs(T.buttons) do if b.shown and b.npcName == name then return b end end
end
local function clean()
    for k in pairs(T.detected) do T.detected[k] = nil end
    WoW.units, WoW.messages, WoW.inCombat = {}, {}, false
    plates = 0
    data.objectives, data.droppers, data.names, data.finishedBy = {}, {}, {}, {}
    WoW.questLog = {}
    StakeoutDB.markerIndex, StakeoutDB.enableMarking = 6, true
    Q.Rebuild()
    for _, m in pairs(QT.members) do m.lastSeen = nil end
    Q.Tick()
end

-- A quest with one creature objective per name, ids from `first`.
local function killQuest(questID, names, first, extra)
    local rows, objs = {}, {}
    for i, n in ipairs(names) do
        rows[i] = row("monster", "0/5 " .. n .. " slain")
        objs[i] = { kind = "creature", id = first + i - 1, name = n }
    end
    local q = { questID = questID, title = "Quest " .. questID, rows = rows }
    for k, v in pairs(extra or {}) do q[k] = v end
    WoW.questLog[#WoW.questLog + 1] = q
    data.objectives[questID] = objs
end

-- A turn-in quest: complete, no rows, ended by `npc`.
local function turnin(questID, npc, id, complete)
    WoW.questLog[#WoW.questLog + 1] = { questID = questID, title = "Report " .. questID, rows = {}, complete = complete ~= false }
    data.objectives[questID] = {}
    data.finishedBy[questID] = { id }
    data.names[id] = npc
end

------------------------------------------------------------
-- The exact macros and markers
------------------------------------------------------------
clean()
killQuest(1, { "Mob A", "Mob B", "Mob C" }, 100)
turnin(2, "Orgnil Soulscar", 3142)
turnin(3, "Gornek", 3143)
Q.Rebuild()
see("Mob A", 100); see("Mob B", 101); see("Mob C", 102)
see("Orgnil Soulscar", 3142, false); see("Gornek", 3143, false)
H.eq(order(), "Orgnil Soulscar,Gornek,Mob A,Mob B,Mob C", "NPCs (friendly row) first, then mobs, each in the order seen")
local b = button("Mob A")
H.eq(b:GetAttribute("macrotext"), "/cleartarget\n/targetexact Mob A\n/cleartarget [dead]",
    "a mob's left click never ends on a corpse")
H.eq(b:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Mob A\n/cleartarget [dead]\n/tm !8",
    "right click adds /tm !8 (skull; ! keeps the mark on a second click)")
H.eq(b:GetAttribute("type2"), "macro", "...as a right-click macro")
H.eq(b:GetAttribute("typerelease"), nil, "no typerelease")
H.eq(button("Mob B"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "7", "the second mob gets the cross")
H.eq(button("Mob C"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "8",
    "the third cycles back to skull: the square is the watch list's marker (6)")
local o = button("Orgnil Soulscar")
H.eq(o:GetAttribute("macrotext"), "/cleartarget\n/targetexact Orgnil Soulscar", "an NPC's left click")
H.eq(o:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Orgnil Soulscar\n/tm !1", "...right click: the star")
H.eq(button("Gornek"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "2", "the next NPC: the circle")
H.check(o.friendly and not b.friendly, "turn-ins are NPCs, kills are mobs")
H.eq(#WoW.sounds, 0, "quest targets never alert")

StakeoutDB.markerIndex = 8
T.RefreshTargetFrame()
H.eq(button("Mob A"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "7", "watch marker skull: mobs start at the cross")
H.eq(button("Mob B"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "6", "...then the square")
StakeoutDB.markerIndex = 1
T.RefreshTargetFrame()
H.eq(button("Gornek"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "2", "watch marker star: NPCs use the circle")
H.eq(button("Orgnil Soulscar"):GetAttribute("macrotext2"):match("/tm !(%d)$"), "2", "...only")
StakeoutDB.enableMarking = false
T.RefreshTargetFrame()
H.eq(button("Mob A"):GetAttribute("macrotext2"), nil, "marking off: no right-click macro")
H.eq(button("Mob A"):GetAttribute("type2"), nil, "...and no right-click action")
H.eq(button("Gornek"):GetAttribute("macrotext2"), nil, "...for NPCs too")
StakeoutDB.markerIndex, StakeoutDB.enableMarking = 6, true

-- A name both a kill and a turn-in: a mob.
clean()
killQuest(1, { "Orgnil Soulscar" }, 3142)
turnin(2, "Orgnil Soulscar", 3142)
Q.Rebuild()
see("Orgnil Soulscar", 3142)
H.check(button("Orgnil Soulscar") and not button("Orgnil Soulscar").friendly, "kill and turn-in on one name: mob wins")
H.eq(count(), 1, "...one button")

------------------------------------------------------------
-- The cap, tiers and the reserved turn-in slot
------------------------------------------------------------
local nine = {}
for i = 1, 9 do nine[i] = "Mob " .. i end

clean()
killQuest(1, nine, 100)
Q.Rebuild()
for i = 1, 9 do see(nine[i], 99 + i) end
H.eq(count(), QT.QUEST_MAX, "at most eight quest buttons")
H.eq(QT.QUEST_MAX, 8, "...eight")

-- Watch-list buttons are outside the cap.
SlashCmdList.STAKEOUT("add Rare Mob")
see("Rare Mob", 999)
H.eq(count(), 9, "a watch button comes on top of the eight")
SlashCmdList.STAKEOUT("remove Rare Mob")

-- Visible beats lingering.
clean()
killQuest(1, nine, 100)
Q.Rebuild()
local first = see(nine[1], 100)
gone(first)                         -- lingering now
for i = 2, 9 do see(nine[i], 99 + i) end
H.eq(button("Mob 1"), nil, "eight visible mobs push out a lingering one")
gone("nameplate9")
H.check(button("Mob 9") and not button("Mob 1"),
    "one of them lingering too: equal tiers, and the incumbent keeps its slot")
WoW.units.nameplate2 = nil
WoW.fire("UNIT_DIED", guid(101))   -- Mob 2 dies: its slot is free
H.check(button("Mob 1") and not button("Mob 2"), "a slot frees up: the lingering one is back")

-- The reserved slot: only when an eligible turn-in exists.
clean()
killQuest(1, nine, 100)
turnin(2, "Orgnil Soulscar", 3142)
Q.Rebuild()
gone(see("Orgnil Soulscar", 3142, false))   -- lingering, so it would lose on tier
for i = 1, 9 do see(nine[i], 99 + i) end
H.check(button("Orgnil Soulscar"), "an eligible turn-in keeps a reserved slot over visible mobs")
H.eq(count(), 8, "...still eight in all")
WoW.questLog[2].complete = false
Q.Rebuild()
H.eq(button("Orgnil Soulscar"), nil, "not complete: no turn-in, no reserved slot")
H.eq(count(), 8, "...eight mobs take every slot")

-- A turn-in the watch list displays is the watch list's: it doesn't take the reserve.
clean()
killQuest(1, nine, 100)
turnin(2, "Orgnil Soulscar", 3142)
Q.Rebuild()
SlashCmdList.STAKEOUT("add Orgnil Soulscar")
see("Orgnil Soulscar", 3142, false)
for i = 1, 9 do see(nine[i], 99 + i) end
local quest = 0
for _, btn in ipairs(T.buttons) do if btn.shown and btn.tooltipLines then quest = quest + 1 end end
H.eq(quest, 8, "the watch list shows the turn-in, and eight quest mobs fill the cap")
H.eq(order():match("^[^,]+"), "Orgnil Soulscar", "...the turn-in on the watch row")
SlashCmdList.STAKEOUT("remove Orgnil Soulscar")

------------------------------------------------------------
-- Fairness over objectives, and stable slots
------------------------------------------------------------
clean()
local function credit(questID, groups)
    local rows, objs = {}, {}
    for i, g in ipairs(groups) do
        rows[i] = row("monster", "0/9 " .. g.root .. " slain")
        local ids = {}
        for k, n in ipairs(g.names) do
            ids[k] = g.first + k - 1
            data.names[ids[k]] = n
        end
        objs[i] = { kind = "killcredit", id = g.first, name = g.root, ids = ids }
    end
    WoW.questLog[#WoW.questLog + 1] = { questID = questID, title = "Credit", rows = rows }
    data.objectives[questID] = objs
end
credit(7, {
    { root = "Alpha", first = 100, names = { "A1", "A2", "A3", "A4", "A5", "A6" } },
    { root = "Beta", first = 200, names = { "B1", "B2", "B3" } },
    { root = "Gamma", first = 300, names = { "C1" } },
})
Q.Rebuild()
for i = 1, 6 do see("A" .. i, 99 + i) end
for i = 1, 2 do see("B" .. i, 199 + i) end
H.eq(order(), "A1,A2,A3,A4,A5,A6,B1,B2", "eight slots, two objectives: all of them")
see("B3", 202)
see("C1", 300)
local sel = {}
for _, btn in ipairs(T.buttons) do if btn.shown then sel[btn.npcName] = true end end
local a = 0
for i = 1, 6 do if sel["A" .. i] then a = a + 1 end end
H.check(sel.C1, "a new objective gets a slot (fairness)")
H.check(sel.B1 and sel.B2 and sel.B3, "the three of B each get one")
H.eq(a, 4, "...which evicts two of A's incumbents of the same tier")
H.check(sel.A1 and sel.A2 and sel.A3 and sel.A4, "...its latest-placed ones")
H.eq(order(), "A1,A2,A3,A4,B1,B2,B3,C1", "incumbents keep their places; the newcomers follow")
local before = order()
WoW.ticker.fn()
T.RefreshTargetFrame()
H.eq(order(), before, "the choice doesn't rotate from one tick to the next")

-- A newcomer that sorts first doesn't push the incumbents along.
clean()
killQuest(1, { "Mob M", "Mob N", "Mob O", "Aardvark" }, 100)
Q.Rebuild()
see("Mob M", 100); see("Mob N", 101); local leaving = see("Mob O", 102)
H.eq(order(), "Mob M,Mob N,Mob O", "three mobs")
see("Aardvark", 103)
H.eq(order(), "Mob M,Mob N,Mob O,Aardvark", "a new one goes after the incumbents")
WoW.fire("UNIT_DIED", guid(102))
H.eq(order(), "Mob M,Mob N,Aardvark", "one leaves: the others keep their order")

------------------------------------------------------------
-- Events: registered, coalesced into one rebuild 0.2 s later
------------------------------------------------------------
for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
                          "QUEST_WATCH_UPDATE", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
                          "PLAYER_ENTERING_WORLD", "PLAYER_LOGIN" }) do
    local registered = false
    for _, evs in pairs(WoW.events) do if evs[event] then registered = true end end
    H.check(registered, event .. " is registered")
end
H.eq(#T.eventFailures, 0, "no registration failed")
clean()
WoW.timers = {}
WoW.fire("QUEST_WATCH_UPDATE", 818)
WoW.fire("QUEST_LOG_UPDATE")
WoW.fire("QUEST_LOG_UPDATE")
WoW.fire("ZONE_CHANGED")
H.eq(#WoW.timers, 1, "a burst of quest events schedules one rebuild")
H.eq(WoW.timers[1] and WoW.timers[1].delay, 0.2, "...0.2 s later")
killQuest(1, { "Mob A" }, 100)
see("Mob A", 100)
H.eq(button("Mob A"), nil, "nothing until the rebuild runs")
WoW.flushTimers()
H.check(button("Mob A"), "the rebuild matches what's on screen and refreshes the frame")

------------------------------------------------------------
-- Combat: nothing protected is touched; one application afterwards
------------------------------------------------------------
clean()
killQuest(1, { "Mob A", "Mob B" }, 100)
Q.Rebuild()
see("Mob A", 100)
local applied = T.lastApplied()
local writes = 0
for _, btn in ipairs(T.buttons) do
    local real = getmetatable(btn).__index.SetAttribute
    btn.SetAttribute = function(self, k, v) writes = writes + 1 return real(self, k, v) end
end
WoW.inCombat = true
local ok, err = pcall(function()
    see("Mob B", 101)                          -- a new target
    WoW.questLog[1].rows[1].finished = true   -- an objective done
    WoW.fire("QUEST_LOG_UPDATE")
    WoW.flushTimers()
    WoW.ticker.fn()
end)
H.check(ok, "sightings, rebuilds and ticks in combat touch nothing protected (" .. tostring(err) .. ")")
H.eq(writes, 0, "...and write no attribute")
H.eq(T.lastApplied(), applied, "the applied layout doesn't advance while it is skipped")
H.check(T.pendingRefresh(), "a refresh is owed")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(order(), "Mob B", "combat's end applies the latest layout")
H.check(writes > 0, "...once")
local after = writes
T.RefreshTargetFrame()
WoW.ticker.fn()
H.eq(writes, after, "and only once: nothing more is written")
for _, btn in ipairs(T.buttons) do btn.SetAttribute = nil end

H.done("test_quests_frame")
