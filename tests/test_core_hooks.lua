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

eq(ns, WoW.ns, "loadAddon hands back the namespace every TOC file shares")
for _, k in ipairs({ "Print", "IsSecret", "ReadNPC", "RegisterEvents", "SetConfig", "RequestFrameRefresh", "Rescan",
                     "MacroSafeName", "IsWatchDisplayed", "IsRefreshPending" }) do
    eq(type(ns.core[k]), "function", "ns.core." .. k)
end
eq(ns.core.NAME_MAX, T.NAME_MAX, "ns.core.NAME_MAX")
eq(type(ns.core.BUTTON_ICONS), "table", "ns.core.BUTTON_ICONS")
eq(type(ns.core.MARKER_ICONS), "table", "ns.core.MARKER_ICONS")
eq(ns.core.RequestFrameRefresh, T.RefreshTargetFrame, "RequestFrameRefresh is the gated refresh")

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
    ButtonSpecs = function() calls.specs = (calls.specs or 0) + 1 return specs end,
}

local function clean()
    for k in pairs(detected) do detected[k] = nil end
    for k in pairs(T.announced) do T.announced[k] = nil end
    WoW.units, WoW.sounds, WoW.chat, WoW.combat = {}, {}, {}, false
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
    for _, b in ipairs(T.buttons) do if b._shown then out[#out + 1] = b.npcName end end
    return table.concat(out, ",")
end

-- The y offset of a button's anchor: which line it is on.
local function lineOf(btn) return math.floor((-(btn._points[#btn._points][5]) - 18) / 28 + 0.5) end
-- Its place in its line: lines are centred, so it's how many shown buttons
-- of the same line sit to its left.
local function colOf(btn)
    local line, x, col = lineOf(btn), btn._points[#btn._points][4], 0
    for _, b in ipairs(T.buttons) do
        if b ~= btn and b._shown and lineOf(b) == line and b._points[#b._points][4] < x then col = col + 1 end
    end
    return col
end
local function xOf(btn) return btn._points[#btn._points][4] end

SlashCmdList.STAKEOUT("add Rare Mob; Twin Mob")

------------------------------------------------------------
-- Fan-out: quest hooks see every unit, watched or not
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Vile Familiar", guid = "Creature-0-1-2-3-3101-A", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
eq(detected["Vile Familiar"], nil, "a non-watched unit is not a watch detection")
eq(#calls.units, 1, "...but reaches the quest hook")
local u = calls.units[1] or {}
eq(u.unit, "nameplate1", "with its token")
eq(u.isPlate, true, "as a plate")
eq(u.name, "Vile Familiar", "with the name the core read")
eq(u.guid, "Creature-0-1-2-3-3101-A", "and its GUID")

WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-R" })
WoW.fire("PLAYER_TARGET_CHANGED")
check(detected["Rare Mob"] ~= nil, "a watched unit is still detected")
eq(calls.units[2] and calls.units[2].name, "Rare Mob", "...and reaches the quest hook too")
eq(calls.units[2] and calls.units[2].isPlate, false, "the target is not a plate")

WoW.SetUnit("nameplate1", nil)
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
eq(calls.removed[1], "nameplate1", "a removed plate reaches the quest hook, watched or not")

WoW.fire("UNIT_DIED", "Creature-0-1-2-3-3101-A")
eq(calls.died[1], "Creature-0-1-2-3-3101-A", "a death reaches the quest hook by GUID")
WoW.fire("UNIT_DIED", WoW.SECRET)
WoW.fire("UNIT_DIED", nil)
eq(#calls.died, 1, "a secret or missing GUID does not")

WoW.ticker.fn()
eq(calls.ticks, 1, "the 1 s ticker runs the quest tick")
WoW.advance(T.LINGER + 1)
WoW.units = {}
WoW.ticker.fn()
eq(detected["Rare Mob"], nil, "...after the watch sweep, which still expires the watch list")

------------------------------------------------------------
-- Resetting the watch list leaves quest state alone
------------------------------------------------------------
clean()
local quests = ns.quests
SlashCmdList.STAKEOUT("reset")
eq(ns.quests, quests, "/stakeout reset keeps Quests.lua's table")
check(questState.members["Vile Familiar"] and questState.members["Vile Familiar"].seen,
    "...and its state")
specs = { spec("Orgnil Soulscar", "friendly") }
T.RefreshTargetFrame()
eq(shownNames(), "Orgnil Soulscar", "quest buttons still render after a watch reset")

------------------------------------------------------------
-- Quest groups render after the watch row, each on its own line
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-R", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
specs = {
    spec("Vile Familiar", "enemy", { macrotext2 = "/cleartarget\n/targetexact Vile Familiar\n/tm !8" }),
    spec("Orgnil Soulscar", "friendly", { tooltip = { "Report to Orgnil" }, clicks = { "Left-click: target" } }),
    spec("Rare Mob", "enemy"),                                -- shown by the watch list already
    spec("Bad\n/run Evil()", "enemy"),                        -- not a name a macro may carry
}
T.RefreshTargetFrame()
eq(shownNames(), "Rare Mob,Orgnil Soulscar,Vile Familiar", "watch, then friendlies, then enemies")
eq(lineOf(T.buttons[1]), 0, "the watch row is line 0")
eq(lineOf(T.buttons[2]), 1, "friendlies start a new line")
eq(colOf(T.buttons[2]), 0, "...at its start")
eq(lineOf(T.buttons[3]), 2, "enemies start another")
eq(T.buttons[3]:GetAttribute("macrotext"), "/cleartarget\n/targetexact Vile Familiar", "a quest button's macro")
eq(T.buttons[3]:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Vile Familiar\n/tm !8", "...and its mark")
eq(T.buttons[3]:GetAttribute("type2"), "macro", "...as a right-click macro")
eq(T.buttons[2].tooltipLines and T.buttons[2].tooltipLines[1], "Report to Orgnil", "its tooltip lines")
-- The rendered tooltip: the quest lines, then the click hints, each from its
-- own field (#98).
T.buttons[2]._scripts.OnEnter(T.buttons[2])
eq(table.concat(GameTooltip._lines or {}, "|"),
    "Orgnil Soulscar|Report to Orgnil|Left-click: target|Shift+right-click: alert when one appears",
    "...and its rendered tooltip: name, quest line, click hints")
T.buttons[2]._scripts.OnLeave(T.buttons[2])
check(T.frame()._shown, "the frame shows")
eq(T.frame()._height, 16 + 3 * 28 + 2 * 9 + 2 + 4, "three lines tall, the two quest lines with their labels")
eq(T.buttons[1].label:GetText(), "", "a watch button has no label: the player typed the name")
eq(T.buttons[2].label:GetText(), "Orgnil Soulscar", "a quest button is labelled with its name")

-- A label drops the words quest buttons share, so two "Kul Tiras" mobs read
-- apart; a name with nothing left to drop stays whole.
specs = { spec("Kul Tiras Sailor", "enemy"), spec("Kul Tiras Marine", "enemy"), spec("Lieutenant Benedict", "enemy") }
T.RefreshTargetFrame()
eq(T.buttons[2].label:GetText(), "Sailor", "Kul Tiras Sailor reads Sailor")
eq(T.buttons[3].label:GetText(), "Marine", "...and Kul Tiras Marine reads Marine")
eq(T.buttons[4].label:GetText(), "Lieutenant Benedict", "a name that shares nothing stays whole")
eq(T.buttons[2].label._width, 28, "a label in the middle of a line fits under its button")
specs = { spec("Kul Tiras Sailor", "enemy") }
T.RefreshTargetFrame()
eq(T.buttons[2].label:GetText(), "Kul Tiras Sailor", "a lone quest button keeps its whole name")
eq(T.buttons[2].label._width, 90 - 8, "...and alone on its line, its label may use the frame's width")
eq(xOf(T.buttons[2]), (90 - 26) / 2, "a lone button is centred in the frame")
eq(xOf(T.buttons[1]), (90 - 26) / 2, "...and so is a lone watch button on its own line")

-- The picture: the face while a token shows the NPC, then for the session
-- wherever that name's button is (as RestedXP keeps them), and never on
-- another NPC's button.
WoW.SetUnit("nameplate2", { name = "Kul Tiras Sailor", guid = "Creature-0-0-0-0-3128-1", plate = true })
specs = { spec("Kul Tiras Sailor", "enemy", { unit = "nameplate2", icon = "QI" }) }
T.RefreshTargetFrame()
local qb = T.buttons[2]
local face = qb.portrait
check(face and face.portrait == "nameplate2" and face:IsShown() and face:GetParent() == qb,
    "in sight, a quest button shows the NPC's face")
eq(qb.icon:IsShown(), false, "...over its icon")
specs = { spec("Kul Tiras Sailor", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
eq(qb.portrait, face, "out of sight, it keeps the face instead of going back to the icon")
specs = { spec("Kul Tiras Marine", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
check(qb.portrait == nil and qb.icon:IsShown() and qb.icon._file == "QI",
    "another NPC in that place gets the icon, not the old face")
eq(face:IsShown(), false, "...and the face is put away")
specs = { spec("Kul Tiras Marine", "enemy", { icon = "QI" }), spec("Kul Tiras Sailor", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
check(T.buttons[3].portrait == face and face:GetParent() == T.buttons[3] and face:IsShown(),
    "the Sailor back, in another place, not in sight: its face follows its name")
eq(T.buttons[2].portrait, nil, "...and the Marine, never seen, keeps the icon")
specs = { spec("Kul Tiras Sailor", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
check(T.buttons[2].portrait == face and face:GetParent() == T.buttons[2] and face:IsShown()
    and T.buttons[3].portrait == nil, "moved back: one face, on one button")

-- Six watch names wrap at five; the quest group still starts on a fresh line.
clean()
SlashCmdList.STAKEOUT("add W1; W2; W3; W4; W5; W6")
for i = 1, 6 do
    WoW.SetUnit("nameplate" .. i, { name = "W" .. i, guid = "Creature-W" .. i, plate = true })
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
end
specs = { spec("Orgnil Soulscar", "friendly") }
T.RefreshTargetFrame()
eq(lineOf(T.buttons[6]), 1, "the sixth watch button wraps")
eq(lineOf(T.buttons[7]), 2, "the quest group starts below it, not beside it")
eq(colOf(T.buttons[7]), 0, "...at the line's start")
SlashCmdList.STAKEOUT("remove W1")
for i = 2, 6 do SlashCmdList.STAKEOUT("remove W" .. i) end

------------------------------------------------------------
-- Dedupe is against the watch buttons on screen, not the list
------------------------------------------------------------
clean()
specs = { spec("Twin Mob", "friendly") }        -- on the watch list, not detected
T.RefreshTargetFrame()
eq(shownNames(), "Twin Mob", "a watched name that isn't shown still gets its quest button")
check(T.buttons[1].tooltipLines == nil and T.buttons[1].friendly, "...as the quest's")
WoW.SetUnit("nameplate1", { name = "Twin Mob", guid = "Creature-T", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
eq(shownNames(), "Twin Mob", "once the watch list shows it, one button")
check(not T.buttons[1].friendly, "...the watch list's")

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
eq(b:GetAttribute("macrotext"), "/cleartarget\n/targetexact Vile Familiar", "the new macro")
eq(b:GetAttribute("type2"), nil, "the old right-click action is gone")
eq(b:GetAttribute("macrotext2"), nil, "...and its mark macro")
eq(b.tooltipLines, nil, "...and its tooltip")
eq(b.npcName, "Vile Familiar", "...and its name")

------------------------------------------------------------
-- An unchanged layout writes no attribute; looks still update
------------------------------------------------------------
clean()
specs = { spec("Vile Familiar", "enemy", { icon = 135274 }) }
T.RefreshTargetFrame()
local applied = T.lastApplied()
countWrites()
T.RefreshTargetFrame()
eq(writes, 0, "the same layout again writes no attribute")
specs[1].icon = 136243
T.RefreshTargetFrame()
eq(writes, 0, "a new icon writes no attribute")
eq(T.buttons[1].icon._file, 136243, "...but shows")
eq(T.lastApplied(), applied, "...and the layout is the same one")
specs[1].macrotext2 = "/cleartarget\n/targetexact Vile Familiar\n/tm !8"
T.RefreshTargetFrame()
check(writes > 0, "a changed macro is written")
for _, btn in ipairs(T.buttons) do btn.SetAttribute = nil end

------------------------------------------------------------
-- Combat: nothing is touched, then one refresh applies it all
------------------------------------------------------------
clean()
specs = { spec("Vile Familiar", "enemy") }
T.RefreshTargetFrame()
applied = T.lastApplied()
countWrites()
WoW.combat = true
specs = { spec("Orgnil Soulscar", "friendly"), spec("Vile Familiar", "enemy") }
local ok, err = pcall(T.RefreshTargetFrame)
check(ok, "a refresh in combat touches nothing protected (" .. tostring(err) .. ")")
eq(writes, 0, "...and writes no attribute")
eq(T.lastApplied(), applied, "a layout skipped in combat is not the applied one")
check(T.pendingRefresh(), "...and a refresh is owed")
check(ns.core.IsRefreshPending(), "Quests.lua can see that (its pane says so)")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(writes > 0, "combat's end applies it")
check(not T.pendingRefresh(), "...and nothing is owed")
eq(shownNames(), "Orgnil Soulscar,Vile Familiar", "...the latest layout")
local after = writes
T.RefreshTargetFrame()
eq(writes, after, "applied once: the next refresh writes nothing")
for _, btn in ipairs(T.buttons) do btn.SetAttribute = nil end

-- A face in combat: an NPC first seen mid-fight is often gone when it ends.
-- The sighting (here Quests.lua's Hold, through CacheFace) draws it on the
-- button's own icon (a texture change, which combat allows) and in the name's
-- cache, which moves onto the button once combat ends.
clean()
local function buttonOf(name)
    for _, b in ipairs(T.buttons) do if b._shown and b.npcName == name then return b end end
end
specs = { spec("Bloodscalp Warrior", "enemy", { icon = "QI" }) }
T.RefreshTargetFrame()
local wb = buttonOf("Bloodscalp Warrior")
eq(wb.portrait, nil, "not seen yet: no face")
countWrites()
WoW.combat = true
WoW.SetUnit("nameplate3", { name = "Bloodscalp Warrior", guid = "Creature-0-0-0-0-597-1", plate = true })
specs = { spec("Bloodscalp Warrior", "enemy", { unit = "nameplate3", icon = "QI" }) }
calls.specs = 0
ok, err = pcall(function()
    T.CacheFace("Bloodscalp Warrior", "nameplate3")
    T.RefreshTargetFrame()
end)
check(ok, "a face in combat throws nothing (" .. tostring(err) .. ")")
eq(calls.specs, 0, "a refresh in combat asks Quests for no buttons: its incumbents stay as rendered (Codex on #90)")
eq(writes, 0, "...writes no attribute")
eq(wb.icon.portrait, "nameplate3", "seen in combat: the face is drawn on the button's icon")
eq(wb.portrait, nil, "...and the cache texture isn't moved onto the protected button in combat")
WoW.units = {}
specs = { spec("Bloodscalp Warrior", "enemy", { icon = "QI" }) }
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
local face = wb.portrait
check(face and face.portrait == "nameplate3" and face:GetParent() == wb and face:IsShown(),
    "out of sight when combat ends: the face drawn in the fight goes on the button")
for _, btn in ipairs(T.buttons) do btn.SetAttribute = nil end

-- A watched NPC with no button yet, seen mid-fight (as the target) and out of
-- sight before combat ends, inside its linger (Codex on #90): the sighting
-- caches its face, and the button it gets after combat shows it.
clean()
SlashCmdList.STAKEOUT("add Brisk Watcher")
WoW.combat = true
WoW.SetUnit("target", { name = "Brisk Watcher", guid = "Creature-0-0-0-0-4242-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
eq(buttonOf("Brisk Watcher"), nil, "in combat: no button yet")
check(detected["Brisk Watcher"] ~= nil, "...but it is detected")
WoW.units = {}
WoW.fire("PLAYER_TARGET_CHANGED")
check(detected["Brisk Watcher"] ~= nil, "...and lingers once it's no longer the target")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
local bw = buttonOf("Brisk Watcher")
check(bw and bw.portrait and bw.portrait.portrait == "target" and bw.portrait:IsShown(),
    "its button after combat shows the face cached at the sighting (button " .. tostring(bw ~= nil)
    .. ", face " .. tostring(bw and bw.portrait and bw.portrait.portrait) .. ")")
SlashCmdList.STAKEOUT("remove Brisk Watcher")

-- Faces go back when their buttons leave the layout (Codex on #90).
clean()
specs = {}
for i = 1, 8 do
    local n = "Face Mob " .. i
    WoW.SetUnit("nameplate" .. i, { name = n, guid = "Creature-0-0-0-0-" .. (500 + i) .. "-1", plate = true })
    specs[i] = spec(n, "enemy", { unit = "nameplate" .. i, icon = "QI" })
end
T.RefreshTargetFrame()
local pictured = 0
for _, b in ipairs(T.buttons) do if b._shown and b.portrait then pictured = pictured + 1 end end
eq(pictured, 8, "eight buttons, eight faces")
specs = { specs[1] }
T.RefreshTargetFrame()
local pinned = 0
for _, b in ipairs(T.buttons) do if not b._shown and b.portrait then pinned = pinned + 1 end end
eq(pinned, 0, "down to one: the seven hidden buttons hold no face")
WoW.units = {}

-- The cap holds even when every face is on a button.
clean()
local names = {}
for i = 1, T.PORTRAIT_MAX + 1 do
    local n = "Cap Mob " .. i
    names[#names + 1] = n
    WoW.SetUnit("nameplate" .. i, { name = n, guid = "Creature-0-0-0-0-" .. (600 + i) .. "-1", plate = true })
end
SlashCmdList.STAKEOUT("add " .. table.concat(names, "; "))
for i = 1, T.PORTRAIT_MAX + 1 do WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
T.RefreshTargetFrame()
check(T.portraitCount() <= T.PORTRAIT_MAX, "never more than " .. T.PORTRAIT_MAX .. " faces (" .. T.portraitCount() .. ")")
local without = 0
for _, b in ipairs(T.buttons) do if b._shown and not b.portrait then without = without + 1 end end
eq(without, 1, "the one past the cap keeps its icon")
WoW.units = {}
SlashCmdList.STAKEOUT("remove " .. table.concat(names, "; "))

-- A full cache, every face on a button: two names leave and a new one comes
-- first. The new one gets a face on that same render (Codex on #90).
clean()
specs = {}
for i = 1, T.PORTRAIT_MAX do
    local n = ("Full Mob %02d"):format(i)
    WoW.SetUnit("nameplate" .. i, { name = n, guid = "Creature-0-0-0-0-" .. (700 + i) .. "-1", plate = true })
    specs[i] = spec(n, "enemy", { unit = "nameplate" .. i, icon = "QI" })
end
T.RefreshTargetFrame()
eq(T.portraitCount(), T.PORTRAIT_MAX, "the cache is full")
local newUnit = "nameplate" .. (T.PORTRAIT_MAX + 1)
WoW.SetUnit(newUnit, { name = "Aardvark Newcomer", guid = "Creature-0-0-0-0-799-1", plate = true })
local kept = { spec("Aardvark Newcomer", "enemy", { unit = newUnit, icon = "QI" }) }
for i = 1, T.PORTRAIT_MAX - 2 do kept[#kept + 1] = specs[i] end
specs = kept
T.RefreshTargetFrame()
local nb = buttonOf("Aardvark Newcomer")
check(nb and nb.portrait and nb.portrait.portrait == newUnit,
    "the newcomer has its face on the first render (" .. tostring(nb and nb.portrait and nb.portrait.portrait) .. ")")
check(T.portraitCount() <= T.PORTRAIT_MAX, "and the cap still holds (" .. T.portraitCount() .. ")")
local faced = 0
for _, b in ipairs(T.buttons) do if b._shown and b.portrait then faced = faced + 1 end end
eq(faced, T.PORTRAIT_MAX - 1, "every shown button has a face")
WoW.units = {}

-- Full again, then two names leave and two new ones come first. The first
-- newcomer takes a survivor's button, so the survivor's face is on no button
-- for a moment; it is the oldest, and its NPC is out of sight. The second
-- newcomer must take a departed face, not the survivor's (Codex on #90).
clean()
specs = {}
for i = 1, T.PORTRAIT_MAX do
    local n = ("Full Mob %02d"):format(i)
    WoW.SetUnit("nameplate" .. i, { name = n, guid = "Creature-0-0-0-0-" .. (700 + i) .. "-1", plate = true })
    specs[i] = spec(n, "enemy", { unit = "nameplate" .. i, icon = "QI" })
end
T.RefreshTargetFrame()
buttonOf("Full Mob 01").portrait.lastUsed = 0
WoW.units = {}
local n1, n2 = "nameplate" .. (T.PORTRAIT_MAX + 1), "nameplate" .. (T.PORTRAIT_MAX + 2)
WoW.SetUnit(n1, { name = "Aardvark One", guid = "Creature-0-0-0-0-801-1", plate = true })
WoW.SetUnit(n2, { name = "Aardvark Two", guid = "Creature-0-0-0-0-802-1", plate = true })
kept = { spec("Aardvark One", "enemy", { unit = n1, icon = "QI" }), spec("Aardvark Two", "enemy", { unit = n2, icon = "QI" }) }
for i = 1, T.PORTRAIT_MAX - 2 do kept[#kept + 1] = spec(("Full Mob %02d"):format(i), "enemy", { icon = "QI" }) end
specs = kept
T.RefreshTargetFrame()
local survivor = buttonOf("Full Mob 01")
check(survivor and survivor.portrait and survivor.portrait.portrait == "nameplate1",
    "the survivor out of sight keeps its face while moving (" .. tostring(survivor and survivor.portrait and survivor.portrait.portrait) .. ")")
local a2 = buttonOf("Aardvark Two")
check(a2 and a2.portrait and a2.portrait.portrait == n2, "and the second newcomer has its own")
check(T.portraitCount() <= T.PORTRAIT_MAX, "the cap holds (" .. T.portraitCount() .. ")")
WoW.units = {}

------------------------------------------------------------
-- MacroSafeName
------------------------------------------------------------
local safe = ns.core.MacroSafeName
check(safe("Orgnil Soulscar"), "a plain name is safe")
check(not safe("A\n/run x"), "a newline is not")
check(not safe("A\tB"), "nor any control character")
check(not safe(""), "nor an empty name")
check(not safe(string.rep("a", T.NAME_MAX + 1)), "nor one longer than NAME_MAX")
check(safe(string.rep("a", T.NAME_MAX)), "NAME_MAX itself is fine")
check(not safe(WoW.SECRET), "nor a secret")
check(not safe(42), "nor a number")

-- Without Quests.lua, the frame is the watch list alone.
clean()
ns.quests = nil
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-R", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.ticker.fn()
eq(shownNames(), "Rare Mob", "no ns.quests: the watch list only, and no error")

done("test_core_hooks")
