------------------------------------------------------------
-- test_core_hooks.lua - what the core gives Quests.lua (#24, phase 1): the
-- ns.core exports, the unit/plate/death/tick fan-out, and the target frame's
-- quest groups, with the applied-layout signature and the combat gate. A fake
-- ns.quests stands in for Quests.lua, set through the shared namespace.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T, ns = WoW.loadAddon()
local detected = T.detected

H.eq(ns, WoW.ns, "loadAddon hands back the namespace every TOC file shares")
for _, k in ipairs({ "Print", "IsSecret", "ReadNPC", "RegisterEvents", "SetConfig", "RequestFrameRefresh", "Rescan",
                     "MacroSafeName", "IsWatchDisplayed", "IsRefreshPending" }) do
    H.eq(type(ns.core[k]), "function", "ns.core." .. k)
end
H.eq(ns.core.NAME_MAX, T.NAME_MAX, "ns.core.NAME_MAX")
H.eq(type(ns.core.BUTTON_ICONS), "table", "ns.core.BUTTON_ICONS")
H.eq(type(ns.core.MARKER_ICONS), "table", "ns.core.MARKER_ICONS")
H.eq(ns.core.RequestFrameRefresh, T.RefreshTargetFrame, "RequestFrameRefresh is the gated refresh")

------------------------------------------------------------
-- The fake Quests.lua
------------------------------------------------------------
local calls, specs
local questState = { members = { ["Vile Familiar"] = { seen = true } } }
local function resetCalls() calls = { units = {}, removed = {}, died = {}, ticks = 0 } end
resetCalls()
specs = {}
ns.quests = {
    OnUnit = function(unit, isPlate, name, guid)
        calls.units[#calls.units + 1] = { unit = unit, isPlate = isPlate, name = name, guid = guid }
    end,
    OnPlateRemoved = function(token) calls.removed[#calls.removed + 1] = token end,
    OnUnitDied = function(guid) calls.died[#calls.died + 1] = guid end,
    Tick = function() calls.ticks = calls.ticks + 1 end,
    ButtonSpecs = function() return specs end,
}

local function clean()
    for k in pairs(detected) do detected[k] = nil end
    for k in pairs(T.announced) do T.announced[k] = nil end
    WoW.units, WoW.sounds, WoW.messages, WoW.inCombat = {}, {}, {}, false
    specs = {}
    resetCalls()
    T.RefreshTargetFrame()
end

local function spec(name, row, extra)
    local s = { name = name, row = row, macrotext = "/cleartarget\n/targetexact " .. name }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

-- How many SetAttribute writes the buttons take from here on.
local writes = 0
local function countWrites()
    writes = 0
    for _, b in ipairs(T.buttons) do
        local real = getmetatable(b).__index.SetAttribute
        b.SetAttribute = function(self, k, v) writes = writes + 1 return real(self, k, v) end
    end
end

local function shownNames()
    local out = {}
    for _, b in ipairs(T.buttons) do if b.shown then out[#out + 1] = b.npcName end end
    return table.concat(out, ",")
end

-- The y offset of a button's anchor: which line it is on.
local function lineOf(btn) return math.floor((-(btn.points[#btn.points][5]) - 18) / 28 + 0.5) end
local function colOf(btn) return math.floor((btn.points[#btn.points][4] - 6) / 28 + 0.5) end

SlashCmdList.STAKEOUT("add Rare Mob; Twin Mob")

------------------------------------------------------------
-- Fan-out: quest hooks see every unit, watched or not
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Vile Familiar", guid = "Creature-0-1-2-3-3101-A", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
H.eq(detected["Vile Familiar"], nil, "a non-watched unit is not a watch detection")
H.eq(#calls.units, 1, "...but reaches the quest hook")
local u = calls.units[1] or {}
H.eq(u.unit, "nameplate1", "with its token")
H.eq(u.isPlate, true, "as a plate")
H.eq(u.name, "Vile Familiar", "with the name the core read")
H.eq(u.guid, "Creature-0-1-2-3-3101-A", "and its GUID")

WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-R" })
WoW.fire("PLAYER_TARGET_CHANGED")
H.check(detected["Rare Mob"] ~= nil, "a watched unit is still detected")
H.eq(calls.units[2] and calls.units[2].name, "Rare Mob", "...and reaches the quest hook too")
H.eq(calls.units[2] and calls.units[2].isPlate, false, "the target is not a plate")

WoW.SetUnit("nameplate1", nil)
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(calls.removed[1], "nameplate1", "a removed plate reaches the quest hook, watched or not")

WoW.fire("UNIT_DIED", "Creature-0-1-2-3-3101-A")
H.eq(calls.died[1], "Creature-0-1-2-3-3101-A", "a death reaches the quest hook by GUID")
WoW.fire("UNIT_DIED", WoW.SECRET)
WoW.fire("UNIT_DIED", nil)
H.eq(#calls.died, 1, "a secret or missing GUID does not")

WoW.ticker.fn()
H.eq(calls.ticks, 1, "the 1 s ticker runs the quest tick")
WoW.advance(T.LINGER + 1)
WoW.units = {}
WoW.ticker.fn()
H.eq(detected["Rare Mob"], nil, "...after the watch sweep, which still expires the watch list")

------------------------------------------------------------
-- Resetting the watch list leaves quest state alone
------------------------------------------------------------
clean()
local quests = ns.quests
SlashCmdList.STAKEOUT("reset")
H.eq(ns.quests, quests, "/stakeout reset keeps Quests.lua's table")
H.check(questState.members["Vile Familiar"] and questState.members["Vile Familiar"].seen,
    "...and its state")
specs = { spec("Orgnil Soulscar", "friendly") }
T.RefreshTargetFrame()
H.eq(shownNames(), "Orgnil Soulscar", "quest buttons still render after a watch reset")

------------------------------------------------------------
-- Quest groups render after the watch row, each on its own line
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-R", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
specs = {
    spec("Vile Familiar", "enemy", { macrotext2 = "/cleartarget\n/targetexact Vile Familiar\n/tm !8" }),
    spec("Orgnil Soulscar", "friendly", { tooltip = { "Report to Orgnil", "Left-click: target" } }),
    spec("Rare Mob", "enemy"),                                -- shown by the watch list already
    spec("Bad\n/run Evil()", "enemy"),                        -- not a name a macro may carry
}
T.RefreshTargetFrame()
H.eq(shownNames(), "Rare Mob,Orgnil Soulscar,Vile Familiar", "watch, then friendlies, then enemies")
H.eq(lineOf(T.buttons[1]), 0, "the watch row is line 0")
H.eq(lineOf(T.buttons[2]), 1, "friendlies start a new line")
H.eq(colOf(T.buttons[2]), 0, "...at its start")
H.eq(lineOf(T.buttons[3]), 2, "enemies start another")
H.eq(T.buttons[3]:GetAttribute("macrotext"), "/cleartarget\n/targetexact Vile Familiar", "a quest button's macro")
H.eq(T.buttons[3]:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Vile Familiar\n/tm !8", "...and its mark")
H.eq(T.buttons[3]:GetAttribute("type2"), "macro", "...as a right-click macro")
H.eq(T.buttons[2].tooltipLines and T.buttons[2].tooltipLines[1], "Report to Orgnil", "its tooltip lines")
H.check(T.frame().shown, "the frame shows")
H.eq(T.frame().height, 16 + 3 * 28 + 2 * 9 + 2 + 4, "three lines tall, the two quest lines with their labels")
H.eq(T.buttons[1].label:GetText(), "", "a watch button has no label: the player typed the name")
H.eq(T.buttons[2].label:GetText(), "Orgnil Soulscar", "a quest button is labelled with its name")

-- A label drops the words quest buttons share, so two "Kul Tiras" mobs read
-- apart; a name with nothing left to drop stays whole.
specs = { spec("Kul Tiras Sailor", "enemy"), spec("Kul Tiras Marine", "enemy"), spec("Lieutenant Benedict", "enemy") }
T.RefreshTargetFrame()
H.eq(T.buttons[2].label:GetText(), "Sailor", "Kul Tiras Sailor reads Sailor")
H.eq(T.buttons[3].label:GetText(), "Marine", "...and Kul Tiras Marine reads Marine")
H.eq(T.buttons[4].label:GetText(), "Lieutenant Benedict", "a name that shares nothing stays whole")

-- The picture: the face while a token shows the NPC, kept while the button
-- lingers after that, and never carried over to another NPC in that place.
WoW.SetUnit("nameplate2", { name = "Kul Tiras Sailor", guid = "Creature-0-0-0-0-3128-1", plate = true })
specs = { spec("Kul Tiras Sailor", "enemy", { unit = "nameplate2", icon = "QI" }) }
T.RefreshTargetFrame()
local qb = T.buttons[2]
H.eq(qb.icon.portrait, "nameplate2", "in sight, a quest button shows the NPC's face")
qb.icon.texture = nil
specs = { spec("Kul Tiras Sailor", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
H.eq(qb.icon.texture, nil, "lingering, it keeps the face instead of going back to the icon")
specs = { spec("Kul Tiras Marine", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
H.eq(qb.icon.texture, "QI", "another NPC in that place gets the icon, not the old face")

-- Six watch names wrap at five; the quest group still starts on a fresh line.
clean()
SlashCmdList.STAKEOUT("add W1; W2; W3; W4; W5; W6")
for i = 1, 6 do
    WoW.SetUnit("nameplate" .. i, { name = "W" .. i, guid = "Creature-W" .. i, plate = true })
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
end
specs = { spec("Orgnil Soulscar", "friendly") }
T.RefreshTargetFrame()
H.eq(lineOf(T.buttons[6]), 1, "the sixth watch button wraps")
H.eq(lineOf(T.buttons[7]), 2, "the quest group starts below it, not beside it")
H.eq(colOf(T.buttons[7]), 0, "...at the line's start")
SlashCmdList.STAKEOUT("remove W1")
for i = 2, 6 do SlashCmdList.STAKEOUT("remove W" .. i) end

------------------------------------------------------------
-- Dedupe is against the watch buttons on screen, not the list
------------------------------------------------------------
clean()
specs = { spec("Twin Mob", "friendly") }        -- on the watch list, not detected
T.RefreshTargetFrame()
H.eq(shownNames(), "Twin Mob", "a watched name that isn't shown still gets its quest button")
H.check(T.buttons[1].tooltipLines == nil and T.buttons[1].friendly, "...as the quest's")
WoW.SetUnit("nameplate1", { name = "Twin Mob", guid = "Creature-T", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
H.eq(shownNames(), "Twin Mob", "once the watch list shows it, one button")
H.check(not T.buttons[1].friendly, "...the watch list's")

------------------------------------------------------------
-- A button that changes role keeps nothing from the old one
------------------------------------------------------------
clean()
specs = { spec("Orgnil Soulscar", "friendly", { macrotext2 = "/cleartarget\n/targetexact Orgnil Soulscar\n/tm !1",
                                                tooltip = { "Report to Orgnil" } }) }
T.RefreshTargetFrame()
specs = { spec("Vile Familiar", "enemy") }
T.RefreshTargetFrame()
local b = T.buttons[1]
H.eq(b:GetAttribute("macrotext"), "/cleartarget\n/targetexact Vile Familiar", "the new macro")
H.eq(b:GetAttribute("type2"), nil, "the old right-click action is gone")
H.eq(b:GetAttribute("macrotext2"), nil, "...and its mark macro")
H.eq(b.tooltipLines, nil, "...and its tooltip")
H.eq(b.npcName, "Vile Familiar", "...and its name")

------------------------------------------------------------
-- An unchanged layout writes no attribute; looks still update
------------------------------------------------------------
clean()
specs = { spec("Vile Familiar", "enemy", { icon = 135274 }) }
T.RefreshTargetFrame()
local applied = T.lastApplied()
countWrites()
T.RefreshTargetFrame()
H.eq(writes, 0, "the same layout again writes no attribute")
specs[1].icon = 136243
T.RefreshTargetFrame()
H.eq(writes, 0, "a new icon writes no attribute")
H.eq(T.buttons[1].icon.texture, 136243, "...but shows")
H.eq(T.lastApplied(), applied, "...and the layout is the same one")
specs[1].macrotext2 = "/cleartarget\n/targetexact Vile Familiar\n/tm !8"
T.RefreshTargetFrame()
H.check(writes > 0, "a changed macro is written")
for _, btn in ipairs(T.buttons) do btn.SetAttribute = nil end

------------------------------------------------------------
-- Combat: nothing is touched, then one refresh applies it all
------------------------------------------------------------
clean()
specs = { spec("Vile Familiar", "enemy") }
T.RefreshTargetFrame()
applied = T.lastApplied()
countWrites()
WoW.inCombat = true
specs = { spec("Orgnil Soulscar", "friendly"), spec("Vile Familiar", "enemy") }
local ok, err = pcall(T.RefreshTargetFrame)
H.check(ok, "a refresh in combat touches nothing protected (" .. tostring(err) .. ")")
H.eq(writes, 0, "...and writes no attribute")
H.eq(T.lastApplied(), applied, "a layout skipped in combat is not the applied one")
H.check(T.pendingRefresh(), "...and a refresh is owed")
H.check(ns.core.IsRefreshPending(), "Quests.lua can see that (its pane says so)")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.check(writes > 0, "combat's end applies it")
H.check(not T.pendingRefresh(), "...and nothing is owed")
H.eq(shownNames(), "Orgnil Soulscar,Vile Familiar", "...the latest layout")
local after = writes
T.RefreshTargetFrame()
H.eq(writes, after, "applied once: the next refresh writes nothing")
for _, btn in ipairs(T.buttons) do btn.SetAttribute = nil end

------------------------------------------------------------
-- MacroSafeName
------------------------------------------------------------
local safe = ns.core.MacroSafeName
H.check(safe("Orgnil Soulscar"), "a plain name is safe")
H.check(not safe("A\n/run x"), "a newline is not")
H.check(not safe("A\tB"), "nor any control character")
H.check(not safe(""), "nor an empty name")
H.check(not safe(string.rep("a", T.NAME_MAX + 1)), "nor one longer than NAME_MAX")
H.check(safe(string.rep("a", T.NAME_MAX)), "NAME_MAX itself is fine")
H.check(not safe(WoW.SECRET), "nor a secret")
H.check(not safe(42), "nor a number")

-- Without Quests.lua, the frame is the watch list alone.
clean()
ns.quests = nil
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-R", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.ticker.fn()
H.eq(shownNames(), "Rare Mob", "no ns.quests: the watch list only, and no error")

H.done("test_core_hooks")
