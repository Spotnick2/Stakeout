------------------------------------------------------------
-- test_quests_model.lua - Quests.lua's model (#24, phase 2): objective
-- association, same-name aggregation, refs that are muted or done, and the
-- mute pruning that waits for an initialized quest log. A fake ns.questData
-- stands in for Phase 3's QuestieDB adapter.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

-- Loaded without PLAYER_LOGIN: the prune guard is tested before login first.
local T, ns = WoW.loadAddon({ login = false })
local Q = ns.quests
local QT = Q._test
local Associate = QT.Associate

------------------------------------------------------------
-- Association (pure)
------------------------------------------------------------
local function row(type, text, finished) return { type = type, text = text, finished = finished or false } end
local function rowsOf(a) local out = {} for i, x in ipairs(a) do out[i] = x.row or false end return out end
local function same(a, b) return table.concat(a, ",") == table.concat(b, ",") end
local function list(t) local out = {} for i, v in ipairs(t) do out[i] = tostring(v) end return table.concat(out, ",") end

-- Mixed types, each to its own kind of row (P1: Legging It, A Solvent Spirit, Thwarting Kolkar).
local a = Associate({
    { kind = "creature", id = 1, name = "Ridgeshade Creeper" },
    { kind = "item", id = 2, name = "Intact Makrura Eye" },
    { kind = "object", id = 3, name = "Attack Plan: Valley of Trials" },
}, {
    row("item", "1/4 Intact Makrura Eye"),
    row("object", "0/1 Attack Plan: Valley of Trials destroyed"),
    row("monster", "0/6 Ridgeshade Creeper slain"),
})
H.eq(list(rowsOf(a)), "3,1,2", "mixed types: creature, item and object each find their row")

-- Kill credit matches a monster row by its root text.
a = Associate({ { kind = "killcredit", id = 9, name = "Kolkar Centaur", ids = { 3273, 3274 } } },
    { row("item", "0/8 Kolkar Centaur Ear"), row("monster", "0/8 Kolkar Centaur slain") })
H.eq(a[1].row, 2, "kill credit takes the monster row, not the item row with the same words")

-- Type-compatible: a creature never takes an item row, even the only one naming it.
a = Associate({ { kind = "creature", id = 1, name = "Makrura" } },
    { row("item", "1/4 Intact Makrura Eye"), row("monster", "0/5 Makrura Clacker slain") })
H.eq(a[1].row, 2, "a creature goes to a monster row only")

-- Unambiguous: one entry, its name in two monster rows -> no text match;
-- one entry vs two rows -> no order match either: progress unknown.
a = Associate({ { kind = "creature", id = 1, name = "Crawler" } },
    { row("monster", "0/6 Pygmy Surf Crawler slain"), row("monster", "0/4 Crawler slain") })
H.eq(a[1].row, nil, "a name in two rows is ambiguous, and counts disagree: progress unknown")
H.eq(a[1].talk, nil, "...still a kill (a monster row is left), not a talk")

-- One match settles another, and a row is never reused.
a = Associate({
    { kind = "creature", id = 2, name = "Crawler" },
    { kind = "creature", id = 1, name = "Pygmy Surf Crawler" },
}, { row("monster", "0/4 Crawler slain"), row("monster", "0/6 Pygmy Surf Crawler slain") })
H.eq(list(rowsOf(a)), "1,2", "the specific name takes its row; the general one gets the row left")

-- Two entries whose one candidate is the same row: neither takes it, and the
-- order fallback doesn't run (two entries, one row).
a = Associate({
    { kind = "creature", id = 1, name = "Surf Crawler" },
    { kind = "creature", id = 2, name = "Pygmy Surf Crawler" },
}, { row("monster", "0/6 Pygmy Surf Crawler slain") })
H.eq(list(rowsOf(a)), "false,false", "two claims on one row: both progress unknown, the row is not shared")

-- Order fallback when the counts agree: QuestieDB's misspelt item (277128).
a = Associate({ { kind = "item", id = 277128, name = "Bloodtalon Martriarch Eggs" } },
    { row("item", "0/1 Bloodtalon Matriarch Eggs") })
H.eq(a[1].row, 1, "a misspelt name still pairs by order: one item entry, one item row")

-- ...and never when they don't.
a = Associate({
    { kind = "item", id = 1, name = "Bloodtalon Martriarch Eggs" },
    { kind = "item", id = 2, name = "Raptor Hide" },
}, { row("item", "0/1 Bloodtalon Matriarch Eggs") })
H.eq(list(rowsOf(a)), "false,false", "two item entries, one item row, no text match: no guess")

-- Order fallback is per type, after the text matches.
a = Associate({
    { kind = "item", id = 1, name = "Misspelt Thing" },
    { kind = "creature", id = 2, name = "Ridgeshade Creeper" },
    { kind = "item", id = 3, name = "Crawler Mucus" },
}, { row("item", "0/1 Mispelled Thing"), row("monster", "0/6 Ridgeshade Creeper slain"), row("item", "1/8 Crawler Mucus") })
H.eq(list(rowsOf(a)), "1,2,3", "text first, then the one item left pairs with the one row left")

-- ObjectiveFirst: the provider orders the entries; the order fallback follows it.
local kc = { kind = "killcredit", id = 10, ids = { 11 } }
local cr = { kind = "creature", id = 20 }
local rows2 = { row("monster", "0/1 Something"), row("monster", "0/3 Another") }
a = Associate({ kc, cr }, rows2)
H.eq(list(rowsOf(a)), "1,2", "kill credit first (ObjectiveFirst): it pairs with the first row")
a = Associate({ cr, kc }, rows2)
H.eq(a[2].row, 2, "the other order pairs the kill credit with the second row: the provider's order is what counts")

-- Forever's type 14: a trainer listed as a creature, the row an "object".
a = Associate({ { kind = "creature", id = 3087, name = "Cook Torka" } },
    { { type = "object", text = "Learn cooking from Cook Torka in Razor Hill", finished = false, objectiveType = 14 } })
H.eq(a[1].row, nil, "a creature never takes an object row (type 14)")
H.eq(a[1].talk, true, "...and with no monster row it is someone to talk to")

------------------------------------------------------------
-- The model over a fake provider
------------------------------------------------------------
local data = { objectives = {}, droppers = {}, names = {}, finishedBy = {} }
ns.questData = {
    Objectives = function(id) return data.objectives[id] end,
    ItemDroppers = function(id) return data.droppers[id] end,
    NpcName = function(id) return data.names[id] end,
    FinishedBy = function(id) return data.finishedBy[id] end,
}

local function guid(id, spawn) return string.format("Creature-0-1-2-3-%d-%s", id, spawn or "A") end
local plates = 0
local function see(name, id, extra)
    plates = plates + 1
    local token = "nameplate" .. plates
    local u = { name = name, guid = guid(id, tostring(plates)), plate = true, attackable = true }
    for k, v in pairs(extra or {}) do u[k] = v end
    WoW.SetUnit(token, u)
    WoW.fire("NAME_PLATE_UNIT_ADDED", token)
    return token
end
local function clean()
    WoW.units, WoW.messages, WoW.inCombat = {}, {}, false
    plates = 0
    StakeoutDB.questMutes = {}   -- test setup, outside the addon
    data.objectives, data.droppers, data.names, data.finishedBy = {}, {}, {}, {}
    WoW.questLog = {}
    Q.Rebuild()
end
local function shown()
    local out = {}
    for _, b in ipairs(T.buttons) do if b.shown then out[#out + 1] = b.npcName end end
    table.sort(out)
    return table.concat(out, ",")
end
local function button(name)
    for _, b in ipairs(T.buttons) do if b.shown and b.npcName == name then return b end end
end

-- A fresh profile has it off; nothing until it is turned on.
H.eq(StakeoutDB.questTargets, false, "quest targets are off by default (experimental)")
WoW.questLog = { { questID = 1, title = "Legging It", rows = { row("monster", "0/6 Ridgeshade Creeper slain") } } }
data.objectives[1] = { { kind = "creature", id = 100, name = "Ridgeshade Creeper" } }
Q.Rebuild()
see("Ridgeshade Creeper", 100)
H.eq(shown(), "", "off: a seen quest mob gets no button")
H.eq(next(QT.members), nil, "...and the model holds nothing")
Q.SetEnabled(true)
WoW.flushTimers()
H.eq(StakeoutDB.questTargets, true, "turned on through the owner")
H.eq(shown(), "Ridgeshade Creeper", "on: the mob already on screen gets its button (rescan)")

-- Item with no known dropper: no button; one with droppers: every dropper.
clean()
WoW.questLog = { { questID = 2, title = "Forever Items", rows = { row("item", "0/3 Shiny Thing"), row("item", "0/4 Crawler Mucus") } } }
data.objectives[2] = { { kind = "item", id = 275713, name = "Shiny Thing" }, { kind = "item", id = 5, name = "Crawler Mucus" } }
data.droppers[5] = { 3106, 3107 }
data.names[3106], data.names[3107] = "Pygmy Surf Crawler", "Surf Crawler"
Q.Rebuild()
H.check(QT.members["id:3106"] and QT.members["id:3107"], "every dropper of the item is a member")
local noSource
for _, ref in ipairs(Q.QuestList()[1].refs) do if ref.objKey == "i275713" then noSource = ref.noSource end end
H.eq(noSource, true, "an item with no dropper is marked no known source")
see("Surf Crawler", 3107)
H.eq(shown(), "Surf Crawler", "a seen dropper gets a button")

-- Type 14 through the model: a talk ref, friendly.
clean()
WoW.questLog = { { questID = 96655, title = "Camping 101: Cooking",
    rows = { { type = "object", text = "Learn cooking from Cook Torka in Razor Hill", objectiveType = 14 } } } }
data.objectives[96655] = { { kind = "creature", id = 3087, name = "Cook Torka" } }
Q.Rebuild()
see("Cook Torka", 3087, { attackable = false })
local b = button("Cook Torka")
H.check(b and b.friendly, "the trainer of a type-14 objective is a friendly talk target, not a kill")
H.eq(b and b:GetAttribute("macrotext"), "/cleartarget\n/targetexact Cook Torka", "...with the NPC macro")

------------------------------------------------------------
-- Same-name aggregation: one button, one place under the cap
------------------------------------------------------------
clean()
local qrows, objs = {}, {}
for i = 1, 8 do
    qrows[i] = row("monster", "0/5 Mob" .. i .. " slain")
    objs[i] = { kind = "creature", id = 200 + i, name = "Mob" .. i }
end
-- Mob1 has a second NPC ID (another objective, same name).
qrows[9] = row("monster", "0/2 Mob1 Elder slain")
objs[9] = { kind = "creature", id = 300, name = "Mob1 Elder" }
WoW.questLog = { { questID = 3, title = "Many", rows = qrows } }
data.objectives[3] = objs
Q.Rebuild()
for i = 1, 8 do see("Mob" .. i, 200 + i) end
see("Mob1", 300)   -- the server calls the elder "Mob1" too: the observed name wins
H.eq(shown(), "Mob1,Mob2,Mob3,Mob4,Mob5,Mob6,Mob7,Mob8",
    "two NPC IDs under one name take one button, and all eight names fit the cap of eight")
local tip = table.concat(button("Mob1").tooltipLines, "|")
H.check(tip:find("Mob1 slain", 1, true) and tip:find("Mob1 Elder slain", 1, true),
    "...and its tooltip names both objectives: " .. tip)

------------------------------------------------------------
-- One ref muted or done never hides another
------------------------------------------------------------
clean()
WoW.questLog = {
    { questID = 10, title = "Quest A", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } },
    { questID = 11, title = "Quest B", rows = { row("monster", "0/4 Pygmy Surf Crawler slain") } },
}
data.objectives[10] = { { kind = "creature", id = 3106, name = "Pygmy Surf Crawler" } }
data.objectives[11] = { { kind = "creature", id = 3106, name = "Pygmy Surf Crawler" } }
Q.Rebuild()
see("Pygmy Surf Crawler", 3106)
H.eq(shown(), "Pygmy Surf Crawler", "wanted by two quests")
local m = QT.members["id:3106"]
H.check(Q.SetMute(Q.TargetMuteKey(m.refs[1], m), true), "a target mute is accepted")
H.eq(StakeoutDB.questMutes["q10:c3106:3106"], true, "keyed q<id>:<objKey>:<npcId>")
H.eq(shown(), "Pygmy Surf Crawler", "muted in quest A, still wanted by quest B")
tip = table.concat(button("Pygmy Surf Crawler").tooltipLines, "|")
H.check(not tip:find("Quest A", 1, true) and tip:find("Quest B", 1, true), "...and only B is in its tooltip")
Q.SetMute(Q.QuestMuteKey(11), true)
H.eq(shown(), "", "both muted: gone")
Q.SetMute(Q.QuestMuteKey(11), false)
H.eq(shown(), "Pygmy Surf Crawler", "unmuted: back")
Q.SetMute(Q.TargetMuteKey(m.refs[1], m), false)
-- Done in quest A, not in B.
WoW.questLog[1].rows[1].finished = true
Q.Rebuild()
H.eq(shown(), "Pygmy Surf Crawler", "done for A, still wanted by B")
WoW.questLog[2].rows[1].finished = true
Q.Rebuild()
H.eq(shown(), "", "done for both: gone")
H.eq(Q.SetMute("x12", true), false, "a malformed mute key is refused")
H.eq(StakeoutDB.questMutes.x12, nil, "...and not written")

-- Progress unknown counts as unfinished until the quest is complete.
clean()
WoW.questLog = { { questID = 12, title = "Unknown", rows = { row("monster", "0/6 Something Else slain"),
    row("monster", "0/2 Yet Another slain") } } }
data.objectives[12] = { { kind = "creature", id = 400, name = "Odd Mob" } }
Q.Rebuild()
see("Odd Mob", 400)
H.eq(shown(), "Odd Mob", "progress unknown: still wanted")
H.check(table.concat(button("Odd Mob").tooltipLines, "|"):find("progress unknown", 1, true), "...and says so")
WoW.questLog[1].complete = true
Q.Rebuild()
H.eq(shown(), "", "once the quest is complete it's done")

------------------------------------------------------------
-- Names from data reach a macro only when MacroSafeName allows
------------------------------------------------------------
clean()
WoW.questLog = { { questID = 13, title = "Unsafe", rows = { row("monster", "0/1 Bad slain") } } }
data.objectives[13] = { { kind = "creature", id = 500, name = "Bad" } }
Q.Rebuild()
see("Bad\n/run Evil()", 500)
H.eq(shown(), "", "a name with a control character never becomes a button")

------------------------------------------------------------
-- Mute pruning: only after an initialized read of the log
------------------------------------------------------------
clean()
WoW.questLog = {}
StakeoutDB.questMutes = { q100 = true, ["q200:c1:1"] = true }
Q.Rebuild()
H.eq(QT.initialized(), false, "before PLAYER_LOGIN the log isn't initialized")
H.eq(StakeoutDB.questMutes.q100, true, "an uninitialized empty read prunes nothing")
WoW.fire("QUEST_LOG_UPDATE")       -- before login: doesn't count
WoW.flushTimers()
H.eq(StakeoutDB.questMutes.q100, true, "a QUEST_LOG_UPDATE before login doesn't initialize it")
WoW.fire("PLAYER_LOGIN")
WoW.flushTimers()
H.eq(QT.initialized(), false, "login alone doesn't either")
H.eq(StakeoutDB.questMutes["q200:c1:1"], true, "...so nothing is pruned yet")
WoW.questLogThrows = true
WoW.fire("QUEST_LOG_UPDATE")
WoW.flushTimers()
H.eq(QT.initialized(), true, "the first QUEST_LOG_UPDATE after login initializes it")
H.eq(StakeoutDB.questMutes.q100, true, "an unreadable log is not an empty one: nothing pruned")
WoW.questLogThrows = false
WoW.questLog = { { questID = 200, title = "Kept", rows = {} } }
Q.Rebuild()
H.eq(StakeoutDB.questMutes.q100, nil, "an initialized read prunes the quest that left")
H.eq(StakeoutDB.questMutes["q200:c1:1"], true, "...and keeps the one still in the log")
WoW.questLog = {}
Q.Rebuild()
H.eq(next(StakeoutDB.questMutes), nil, "a genuinely empty, initialized log prunes everything")

-- Headers in the log are not quests.
WoW.questLog = { { header = true, title = "Durotar" }, { questID = 818, title = "A Solvent Spirit", rows = {} } }
Q.Rebuild()
H.eq(#Q.QuestList(), 1, "a header line is skipped")
H.eq(Q.QuestList()[1].questID, 818, "...and the quest under it is read")

-- A provider that throws, or answers garbage, is no provider for that quest.
clean()
ns.questData.Objectives = function(id)
    if id == 20 then error("boom") end
    return { { kind = "creature" } }   -- no id: malformed
end
WoW.questLog = {
    { questID = 20, title = "Throws", rows = { row("monster", "0/6 Ridgeshade Creeper slain") } },
    { questID = 21, title = "Garbage", rows = { row("monster", "0/6 Makrura Clacker slain") } },
}
H.check(pcall(Q.Rebuild), "a throwing provider doesn't break the rebuild")
see("Ridgeshade Creeper", 100)
see("Makrura Clacker", 3103)
H.eq(shown(), "Makrura Clacker,Ridgeshade Creeper", "both quests fall back to the name rule")

H.done("test_quests_model")
