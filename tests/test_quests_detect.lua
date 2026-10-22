------------------------------------------------------------
-- test_quests_detect.lua - how Quests.lua matches the units the core sees
-- (#24, phase 2): by NPC ID, by name, by the name rule without a provider,
-- and the "other quest units" fallback; rows from what the quest wants, never
-- the unit's colour; secret values; the sighting lifecycle; and living next
-- to the watch list (rescans, resets, dedupe).
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T, ns = WoW.loadAddon({ savedDB = { questTargets = true } })
local Q = ns.quests
local QT = Q._test
WoW.flushTimers()

local function row(type, text, finished) return { type = type, text = text, finished = finished or false } end
local function guid(id, spawn) return string.format("Creature-0-1-2-3-%d-%s", id, spawn or "A") end
local function shown()
    local out = {}
    for _, b in ipairs(T.buttons) do if b.shown then out[#out + 1] = b.npcName end end
    table.sort(out)
    return table.concat(out, ",")
end
local function button(name)
    for _, b in ipairs(T.buttons) do if b.shown and b.npcName == name then return b end end
end
local function clean()
    for k in pairs(T.detected) do T.detected[k] = nil end
    for k in pairs(T.announced) do T.announced[k] = nil end
    WoW.units, WoW.messages, WoW.sounds, WoW.inCombat = {}, {}, {}, false
    WoW.questLog, WoW.questLogHidden = {}, nil
    ns.questData = nil
    if StakeoutDB.questOther then Q.SetOther(false) end
    WoW.flushTimers()
    Q.Rebuild()
    -- Nothing lingers from the last case.
    for _, m in pairs(QT.members) do m.lastSeen = nil end
    WoW.advance(ns.core.LINGER + 1)
    Q.Tick()
end
local function plate(token, info)
    info.plate = true
    WoW.SetUnit(token, info)
    WoW.fire("NAME_PLATE_UNIT_ADDED", token)
end

H.eq(type(ns.quests.OnUnit), "function", "Quests.lua sets ns.quests")
H.eq(QT.NpcIdFromGuid("Creature-0-6782-1-2-3103-C322B76B08"), 3103, "the NPC ID of a plain creature GUID")
H.eq(QT.NpcIdFromGuid("Player-1-0ABC"), nil, "a player GUID has none")
H.eq(QT.NpcIdFromGuid(WoW.SECRET), nil, "a secret GUID has none, and isn't touched")

------------------------------------------------------------
-- No provider: the name rule (the Questie-less subset)
------------------------------------------------------------
clean()
WoW.questLog = { { questID = 96821, title = "Legging It", rows = {
    row("monster", "0/6 Ridgeshade Creeper slain"),
    row("item", "0/8 Crawler Mucus"),
    row("monster", "6/6 Makrura Clacker slain", true),
} } }
Q.Rebuild()
plate("nameplate1", { name = "Ridgeshade Creeper", guid = guid(3112), attackable = true })
plate("nameplate2", { name = "Crawler", guid = guid(3106), attackable = true })         -- in an item row only
plate("nameplate3", { name = "Makrura Clacker", guid = guid(3103), attackable = true }) -- its row is finished
plate("nameplate4", { name = "Boar", guid = guid(3098), attackable = true })            -- not in any row
H.eq(shown(), "Ridgeshade Creeper", "a seen unit named in an unfinished monster row gets a button; nothing else")
H.check(QT.members["n:Ridgeshade Creeper"], "...as a name member, objKey n:<name>")
H.check(not button("Ridgeshade Creeper").friendly, "...a mob")
H.eq(next(StakeoutDB.questMutes or {}), nil, "seeing writes no setting")

-- A neutral (reaction 4) crawler that a kill objective wants is a mob.
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106), attackable = true, reaction = 4 })
H.check(button("Pygmy Surf Crawler") and not button("Pygmy Surf Crawler").friendly,
    "a neutral (yellow) kill mob goes in the mob row")
local code = (assert(io.open("Quests.lua")):read("*a")):gsub("%-%-[^\n]*", "")
H.check(not code:find("UnitReaction", 1, true), "Quests.lua never reads UnitReaction")
H.check(not code:find("TargetUnit", 1, true) and not code:find("SetRaidTarget", 1, true),
    "...nor the forbidden TargetUnit or SetRaidTarget")

------------------------------------------------------------
-- The "other quest units" fallback: off by default
------------------------------------------------------------
clean()
H.eq(StakeoutDB.questOther, false, "other quest units are off by default")
plate("nameplate1", { name = "Venomtail Raptor", guid = guid(3254), related = true, attackable = true })
H.eq(shown(), "", "off: a related unit matching no objective gets nothing")
Q.SetOther(true)
WoW.flushTimers()
H.eq(shown(), "Venomtail Raptor", "on: it gets a button (rescan after the rebuild)")
H.check(not button("Venomtail Raptor").friendly, "attackable: the mob row (UnitCanAttack)")
H.check(QT.members["o:Venomtail Raptor"].other, "...ref-less")
plate("nameplate2", { name = "Gornek", guid = guid(3143), related = true, attackable = false })
H.check(button("Gornek") and button("Gornek").friendly, "not attackable: the NPC row")
plate("nameplate3", { name = "Sly Mob", guid = guid(9), related = WoW.SECRET, attackable = true })
H.eq(button("Sly Mob"), nil, "a secret relatedness is not related")
plate("nameplate4", { name = "Unrelated", guid = guid(10), related = false, attackable = true })
H.eq(button("Unrelated"), nil, "an unrelated unit gets nothing")
-- Re-checked after every rebuild.
WoW.units.nameplate1.related = false
Q.Rebuild()
H.eq(button("Venomtail Raptor"), nil, "no longer related after a rebuild: dropped")
H.check(button("Gornek"), "...the one still related stays")
-- An objective wins over the fallback, and ranks before it.
WoW.questLog = { { questID = 2, title = "Gornek", rows = { row("monster", "0/1 Gornek slain") } } }
Q.Rebuild()
H.eq(QT.members["o:Gornek"], nil, "a unit an objective now names is no longer an other quest unit")
H.check(QT.members["n:Gornek"], "...it's that objective's")
Q.SetOther(false)
WoW.flushTimers()
H.eq(QT.members["o:Gornek"], nil, "turning the fallback off drops its units")

------------------------------------------------------------
-- With a provider: by NPC ID, then by name
------------------------------------------------------------
clean()
local data = { objectives = {}, droppers = {}, names = {}, finishedBy = {} }
local provider = {
    Objectives = function(id) return data.objectives[id] end,
    ItemDroppers = function(id) return data.droppers[id] end,
    NpcName = function(id) return data.names[id] end,
    FinishedBy = function(id) return data.finishedBy[id] end,
}
ns.questData = provider
WoW.questLog = { { questID = 97223, title = "Bloodtalon Matriarch", rows = { row("item", "0/1 Bloodtalon Matriarch Eggs") } },
                 { questID = 823, title = "Report to Orgnil", rows = {}, complete = true } }
data.objectives[97223] = { { kind = "item", id = 277128, name = "Bloodtalon Martriarch Eggs" } }
data.objectives[823] = {}
data.droppers[277128] = { 3247 }
data.names[3247] = "Bloodtalon Matriarch"   -- the provider's spelling
data.finishedBy[823] = { 3142 }
data.names[3142] = "Orgnil Soulscar"
Q.Rebuild()
plate("nameplate1", { name = "Bloodtalon Matriarch ", guid = guid(3247), attackable = true })
H.eq(shown(), "Bloodtalon Matriarch ", "matched by NPC ID; the observed name is what /targetexact uses")
H.eq(button("Bloodtalon Matriarch ") and button("Bloodtalon Matriarch "):GetAttribute("macrotext"),
    "/cleartarget\n/targetexact Bloodtalon Matriarch \n/cleartarget [dead]", "...in the macro")
-- A secret GUID: matched by the provider's name instead.
WoW.SetUnit("target", { name = "Orgnil Soulscar", secretGuid = true, attackable = false })
WoW.fire("PLAYER_TARGET_CHANGED")
H.check(button("Orgnil Soulscar") and button("Orgnil Soulscar").friendly,
    "an unreadable GUID falls back to the name; a turn-in is an NPC")
H.eq(button("Orgnil Soulscar"):GetAttribute("macrotext"), "/cleartarget\n/targetexact Orgnil Soulscar",
    "...whose left click has no /cleartarget [dead]")

------------------------------------------------------------
-- Secret names and GUIDs are never compared
------------------------------------------------------------
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", secretName = true, guid = guid(3106) })
H.eq(shown(), "", "a secret name is no sighting")
local ok, err = pcall(Q.OnUnit, "nameplate2", true, WoW.SECRET, WoW.SECRET)
H.check(ok, "a secret passed straight in is not touched (" .. tostring(err) .. ")")
H.eq(QT.holders.nameplate2 and next(QT.holders.nameplate2), nil, "...and holds nothing")
ok, err = pcall(Q.OnUnitDied, WoW.SECRET)
H.check(ok, "a secret death GUID is not touched (" .. tostring(err) .. ")")
ok, err = pcall(Q.OnPlateRemoved, WoW.SECRET)
H.check(ok, "nor a secret plate token (" .. tostring(err) .. ")")
plate("nameplate3", { name = "Pygmy Surf Crawler", secretGuid = true })
H.eq(shown(), "Pygmy Surf Crawler", "a secret GUID with a plain name still matches by name")
WoW.units.nameplate4 = { name = "X", throws = true, plate = true }
ok = pcall(WoW.fire, "NAME_PLATE_UNIT_ADDED", "nameplate4")
H.check(ok, "a unit whose reads throw breaks nothing")

------------------------------------------------------------
-- The sighting lifecycle: visible, lingering LINGER s, over at a death
------------------------------------------------------------
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
local m = QT.members["n:Pygmy Surf Crawler"]
H.eq(m.tier, 3, "on a plate: visible")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(m.tier, 2, "plate gone: lingering")
H.eq(shown(), "Pygmy Surf Crawler", "...the button stays")
WoW.advance(ns.core.LINGER - 1)
WoW.ticker.fn()
H.eq(shown(), "Pygmy Surf Crawler", "still there just inside LINGER")
WoW.advance(2)
WoW.ticker.fn()
H.eq(shown(), "", "gone after LINGER")
H.eq(QT.members["n:Pygmy Surf Crawler"], nil, "a name member goes with its sighting")

plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
WoW.fire("UNIT_DIED", guid(3106, "1"))
H.eq(shown(), "", "its death ends the sighting at once, plate or not")
-- Two of the name: one death doesn't end the other's.
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
plate("nameplate2", { name = "Pygmy Surf Crawler", guid = guid(3106, "2"), attackable = true })
WoW.units.nameplate1 = nil
WoW.fire("UNIT_DIED", guid(3106, "1"))
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(shown(), "Pygmy Surf Crawler", "the other one's plate keeps it")
-- An old GUID doesn't outlive its sighting (Codex on #45): crawler 1 seen
-- and gone out of sight, crawler 2 seen past LINGER, then 2 dies.
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
plate("nameplate2", { name = "Pygmy Surf Crawler", guid = guid(3106, "2"), attackable = true })
WoW.advance(ns.core.LINGER + 1)
WoW.ticker.fn()
WoW.units.nameplate2 = nil
WoW.fire("UNIT_DIED", guid(3106, "2"))
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
H.eq(shown(), "", "the one in sight dies: over at once, whatever was seen before it")
-- A death while it lingers still ends it at once (its GUID outlives the plate
-- for LINGER, Codex on #45).
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(shown(), "Pygmy Surf Crawler", "out of sight: lingering")
WoW.fire("UNIT_DIED", guid(3106, "1"))
H.eq(shown(), "", "killed while it lingers: over at once")
-- A plate reused for another one of the name, with no removal in between:
-- the first one's GUID departs then, and expires after LINGER.
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "2"), attackable = true })
WoW.advance(ns.core.LINGER + 1)
WoW.ticker.fn()
WoW.units.nameplate1 = nil
WoW.fire("UNIT_DIED", guid(3106, "2"))
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(shown(), "", "the second one dies: over at once, the reused plate's first GUID long expired")
-- Partial reads (a collapsed header) keep the quests they missed, read again
-- by ID so their progress stays current (Codex on #45).
clean()
local crawlers = { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } }
WoW.questLog = { crawlers }
Q.Rebuild()
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106, "1"), attackable = true })
H.eq(shown(), "Pygmy Surf Crawler", "a crawler in sight has its button")
WoW.questLog, WoW.questLogHidden = {}, { crawlers }
Q.Rebuild()
H.eq(shown(), "Pygmy Surf Crawler", "its quest hidden under a collapsed header: the button stays")
crawlers.rows[1] = row("monster", "6/6 Pygmy Surf Crawler slain", true)
Q.Rebuild()
H.eq(shown(), "", "the hidden quest's objective finishes: the button goes")
crawlers.rows[1] = row("monster", "5/6 Pygmy Surf Crawler slain")
Q.Rebuild()
H.eq(shown(), "Pygmy Surf Crawler", "unfinished again (still hidden): the crawler in sight is back")
WoW.questLogHidden = { { questID = 2, title = "Another hidden", rows = {} } }
Q.Rebuild()
H.eq(shown(), "", "turned in while hidden (the read still partial): it goes at once")
H.eq(#Q.QuestList(), 0, "...and leaves the quest list, though the read was partial")
WoW.questLogHidden = nil
WoW.questLog = { crawlers }
Q.Rebuild()
H.eq(shown(), "Pygmy Surf Crawler", "back in the shown rows: its button returns")
WoW.questLog = {}
Q.Rebuild()
H.eq(shown(), "", "a whole read without the quest: it goes")
-- A stale token (a missed removal, a reused plate) is dropped by the tick.
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
plate("nameplate2", { name = "Pygmy Surf Crawler", guid = guid(3106, "2"), attackable = true })
WoW.units.nameplate2 = { name = "Boar", guid = guid(3098), plate = true }
WoW.ticker.fn()
H.eq(QT.members["n:Pygmy Surf Crawler"].tier, 2, "a plate now showing another unit no longer counts")
-- The target and the mouseover count, and stop counting when they change.
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
WoW.SetUnit("mouseover", { name = "Pygmy Surf Crawler", guid = guid(3106) })
WoW.fire("UPDATE_MOUSEOVER_UNIT")
H.eq(QT.members["n:Pygmy Surf Crawler"].tier, 3, "under the mouse: visible")
WoW.SetUnit("mouseover", nil)
WoW.fire("UPDATE_MOUSEOVER_UNIT")
H.eq(QT.members["n:Pygmy Surf Crawler"].tier, 2, "mouse moved off: lingering")

------------------------------------------------------------
-- Alongside the watch list
------------------------------------------------------------
-- Quest-only mobs reach the hooks: no watch-list entry needed (above). A unit
-- already on screen is matched after a rebuild, and a watched one doesn't alert
-- twice.
clean()
SlashCmdList.STAKEOUT("add Makrura Clacker")
plate("nameplate1", { name = "Makrura Clacker", guid = guid(3103), attackable = true })
plate("nameplate2", { name = "Ridgeshade Creeper", guid = guid(3112), attackable = true })
H.eq(#WoW.sounds, 1, "the watched one alerted once")
H.eq(shown(), "Makrura Clacker", "no quest yet: only the watch button")
WoW.questLog = { { questID = 5, title = "Two", rows = { row("monster", "0/5 Makrura Clacker slain"),
    row("monster", "0/6 Ridgeshade Creeper slain") } } }
WoW.fire("QUEST_ACCEPTED", 5)
WoW.fire("QUEST_LOG_UPDATE")
WoW.flushTimers()
H.eq(shown(), "Makrura Clacker,Ridgeshade Creeper", "the unit already on screen is matched after the rebuild")
H.eq(#WoW.sounds, 1, "...and the watched one didn't alert again")
local count = 0
for _, b in ipairs(T.buttons) do if b.shown and b.npcName == "Makrura Clacker" then count = count + 1 end end
H.eq(count, 1, "a name the watch list shows has one button, the watch list's")

-- A watch reset leaves quest state alone.
WoW.units.nameplate2 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
local before = QT.members["n:Ridgeshade Creeper"]
SlashCmdList.STAKEOUT("reset")
H.eq(QT.members["n:Ridgeshade Creeper"], before, "/stakeout reset keeps the quest members")
H.eq(before.tier, 2, "...and their sighting (still lingering)")
H.check(button("Ridgeshade Creeper"), "...and their button")

-- A watched name the watch list isn't showing still gets its quest button:
-- the watch list drops a name at once when its plate goes, the quest lingers.
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(T.detected["Makrura Clacker"], nil, "the watch list no longer shows it")
H.check(button("Makrura Clacker") and button("Makrura Clacker").tooltipLines,
    "...and the quest's own button takes over")
SlashCmdList.STAKEOUT("remove Makrura Clacker")

------------------------------------------------------------
-- Turned off: hooks are no-ops, no buttons
------------------------------------------------------------
clean()
WoW.questLog = { { questID = 1, title = "Crawlers", rows = { row("monster", "0/6 Pygmy Surf Crawler slain") } } }
Q.Rebuild()
SlashCmdList.STAKEOUT("quests off")
H.eq(StakeoutDB.questTargets, false, "/stakeout quests off")
plate("nameplate1", { name = "Pygmy Surf Crawler", guid = guid(3106), attackable = true })
H.eq(shown(), "", "off: no quest button")
H.eq(next(QT.members), nil, "...and nothing kept")
SlashCmdList.STAKEOUT("quests on")
WoW.flushTimers()
H.eq(shown(), "Pygmy Surf Crawler", "back on: the visible mob is matched again")

H.done("test_quests_detect")
