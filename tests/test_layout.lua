------------------------------------------------------------
-- test_layout.lua - the target frame's layouts (#88): Icons, List and List,
-- two columns. The same secure buttons are placed and dressed differently:
-- a layout switch alone writes no attribute, rows are wide enough for whole
-- names and any status they can come to show, a row with no face yet shows
-- the shadowed placeholder, and the target's button wears an outline in both
-- layouts. A fake ns.quests gives the quest rows, as in test_core_hooks.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T, ns = WoW.loadAddon()
local detected = T.detected
local CW = 6   -- the kit's text width: 6 units a character (WowTestKit #107)

local specs = {}
ns.quests = {
    OnUnit = function() end, OnPlateRemoved = function() end, OnUnitDied = function() end, Tick = function() end,
    ButtonSpecs = function() return specs end,
}

local function spec(name, row, extra)
    local s = { name = name, row = row, macrotext = "/cleartarget\n/targetexact " .. name }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local function clean()
    for k in pairs(detected) do detected[k] = nil end
    for k in pairs(T.announced) do T.announced[k] = nil end
    WoW.units, WoW.sounds, WoW.chat, WoW.combat = {}, {}, {}, false
    specs = {}
    T.RefreshTargetFrame()
end

local writes = 0
local function countWrites()
    writes = 0
    for _, b in ipairs(T.buttons) do
        local real = getmetatable(b).__index.SetAttribute
        b.SetAttribute = function(self, k, v) writes = writes + 1 return real(self, k, v) end
    end
end
local function stopCounting() for _, b in ipairs(T.buttons) do b.SetAttribute = nil end end

local function buttonOf(name)
    for _, b in ipairs(T.buttons) do if b._shown and b.npcName == name then return b end end
end

local function anchor(w) return w._points[#w._points] end

-- Every shown row and group title as a box, and how many overlap.
local function overlaps()
    local f, boxes = T.frame(), {}
    for _, b in ipairs(T.buttons) do
        if b._shown then
            local p = anchor(b)
            boxes[#boxes + 1] = { x1 = p[4], x2 = p[4] + b._width, top = -p[5], bottom = -p[5] + b._height }
        end
    end
    for _, h in ipairs(f.groupHeaders or {}) do
        if h._shown then
            local p = anchor(h)
            boxes[#boxes + 1] = { x1 = 0, x2 = f._width, top = -p[5], bottom = -p[5] + 12 }
        end
    end
    local bad = 0
    for i = 1, #boxes do
        for j = i + 1, #boxes do
            local a, c = boxes[i], boxes[j]
            if a.x1 < c.x2 and c.x1 < a.x2 and a.top < c.bottom and c.top < a.bottom then bad = bad + 1 end
        end
    end
    return bad, #boxes
end

local function shownHeaders()
    local out = {}
    for _, h in ipairs(T.frame().groupHeaders or {}) do if h._shown then out[#out + 1] = h:GetText() end end
    return table.concat(out, ",")
end

-- The row width RowGeometry should give: the face, the widest name, the
-- widest status ("not seen" at least), the pads; within the bounds.
local function rowWidth(longestName, widestStatus)
    local status = math.max(#"not seen", widestStatus or 0) * CW
    local w = 2 + (T.ROW_H - 4) + 6 + #longestName * CW + 8 + status + 6
    return math.min(T.ROW_W_MAX, math.max(T.ROW_W_MIN, w))
end

------------------------------------------------------------
-- The setting
------------------------------------------------------------
eq(StakeoutDB.layout, "icons", "Icons by default")
SlashCmdList.STAKEOUT("layout sideways")
eq(StakeoutDB.layout, "icons", "a bad value is refused")
check(WoW.chatText():find("Use /stakeout layout icons", 1, true) or WoW.chatText():find("layout icons", 1, true),
    "...and the command says what it takes")
SlashCmdList.STAKEOUT("config")
local dd = StakeoutConfigFrame.layoutDropdown
eq(dd and dd.text, "Icons", "the settings' Layout dropdown shows it")
SlashCmdList.STAKEOUT("layout list2")
eq(StakeoutDB.layout, "list2", "/stakeout layout list2")
eq(dd.text, "List, two columns", "the dropdown follows a slash change")
-- The dropdown's own entries set it too.
local picked = {}
local realAdd = UIDropDownMenu_AddButton
UIDropDownMenu_AddButton = function(info) picked[#picked + 1] = info end
dd.initFn()
UIDropDownMenu_AddButton = realAdd
eq(#picked, 3, "three entries")
picked[2].func()
eq(StakeoutDB.layout, "list", "choosing List in the dropdown")
eq(dd.text, "List", "...and it says so")
SlashCmdList.STAKEOUT("config")
SlashCmdList.STAKEOUT("layout icons")

------------------------------------------------------------
-- The list: rows with whole names, grouped, no writes on a switch
------------------------------------------------------------
clean()
SlashCmdList.STAKEOUT("add Watched Rare; Second Rare")
WoW.SetUnit("nameplate1", { name = "Watched Rare", guid = "Creature-0-0-0-0-1-1", plate = true })
WoW.SetUnit("nameplate2", { name = "Second Rare", guid = "Creature-0-0-0-0-2-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
WoW.units = {}   -- out of sight: lingering, no face drawn
specs = {
    spec("Gnome Questgiver", "friendly", { progress = "turn in" }),
    spec("Stranglethorn Tiger", "enemy", { progress = "4/10", progressMax = "10/10" }),
    spec("Jungle Stalker", "enemy", { progress = "3/10", progressMax = "10/10", hunt = true }),
    spec("Kurzen Commando", "enemy", { hunt = true }),
}
T.RefreshTargetFrame()
local icon = T.buttons[1]
eq(icon._width .. "x" .. icon._height, "26x26", "icons: 26 px buttons")

countWrites()
SlashCmdList.STAKEOUT("layout list")
eq(writes, 0, "Icons -> List writes no attribute")
local tiger = buttonOf("Stranglethorn Tiger")
eq(tiger._width, rowWidth("Stranglethorn Tiger"), "a row as wide as the widest name and status need")
eq(tiger._height, T.ROW_H, "...and ROW_H tall")
eq(tiger.nameText:GetText(), "Stranglethorn Tiger", "the whole name")
check(tiger.nameText._shown and not tiger.label._shown, "the name on the row, the label under it hidden")
check(tiger.backing._shown, "the dark backing under the row")
eq(tiger.progress:GetText(), "4/10", "its progress on the right")
eq(buttonOf("Gnome Questgiver").progress:GetText(), "turn in", "a turn-in says so")
local stalker = buttonOf("Jungle Stalker")
eq(stalker.progress:GetText(), "3/10", "a hunt row with a count shows the count")
eq(stalker.nameText._textColor and stalker.nameText._textColor[1], 0.65, "...its name greyed")
eq(buttonOf("Kurzen Commando").progress:GetText(), "not seen", "a hunt row with nothing else: not seen")
eq(buttonOf("Watched Rare").progress:GetText(), "", "a watch row: nothing on the right")
eq(buttonOf("Watched Rare").nameText._textColor[1], 1, "...and its name white")
eq(shownHeaders(), "Watch list,NPCs,Quest mobs", "a title per group")
local bad, n = overlaps()
eq(bad, 0, "list: nothing overlaps (" .. n .. " rows and titles)")
-- No face yet: the shadowed placeholder, never a tinted icon.
check(tiger.placeholder._shown and not tiger.icon._shown, "no face yet: the placeholder")
check(tiger.placeholder._desaturated, "...shadowed")
eq(tiger.icon._vertex, nil, "the icon itself is never tinted")

countWrites()
SlashCmdList.STAKEOUT("layout list2")
eq(writes, 0, "List -> two columns writes no attribute")
bad, n = overlaps()
eq(bad, 0, "two columns: nothing overlaps, a full line before a new group and an odd last row included (" .. n .. ")")
-- Sorted by name: Second Rare on the left.
local w1, w2 = buttonOf("Second Rare"), buttonOf("Watched Rare")
eq(anchor(w1)[5], anchor(w2)[5], "two watch rows share a line")
check(anchor(w2)[4] > anchor(w1)[4], "...side by side")
local npc = buttonOf("Gnome Questgiver")
eq(anchor(npc)[4], anchor(w1)[4], "a group's odd row takes the left column")
local last = buttonOf("Kurzen Commando")
eq(anchor(last)[4], anchor(w1)[4], "...and so does the last mob, alone on its line")
eq(T.frame()._width, 2 * 6 + 2 * tiger._width + 2, "the frame fits two columns")

------------------------------------------------------------
-- Width: whole names, a cap, and room for any status a row comes to
------------------------------------------------------------
countWrites()
local long = string.rep("Longname ", 10)   -- 90 characters: past the cap
specs[#specs + 1] = spec(long, "enemy")
T.RefreshTargetFrame()
stopCounting()
eq(buttonOf(long)._width, T.ROW_W_MAX, "a very long name: the rows stop at ROW_W_MAX")
specs[#specs] = nil
T.RefreshTargetFrame()

SlashCmdList.STAKEOUT("layout list")
clean()
local name = "Venture Company Shredder"   -- 24 characters
specs = { spec(name, "enemy", { hunt = true }) }
T.RefreshTargetFrame()
local row = buttonOf(name)
local before = row._width
eq(before, rowWidth(name), "a long name with not seen: its width")
countWrites()
specs = { spec(name, "enemy", { hunt = true, progress = "0/1000", progressMax = "1000/1000" }) }
T.RefreshTargetFrame()
eq(writes, 0, "a count wider than not seen: no attribute written")
eq(row._width, rowWidth(name, #"1000/1000"), "...and the row is at once as wide as the count at its end")
check(row._width > before, "wider than before")
eq(row.progress._width, #"1000/1000" * CW, "the status column fits the count at its end")
-- The count reaching its end moves nothing.
local reserved = row._width
local placed = 0
local realSetSize = getmetatable(row).__index.SetSize
row.SetSize = function(self, ...) placed = placed + 1 return realSetSize(self, ...) end
specs = { spec(name, "enemy", { hunt = true, progress = "1000/1000", progressMax = "1000/1000" }) }
T.RefreshTargetFrame()
row.SetSize = nil
eq(row.progress:GetText(), "1000/1000", "the count at its end")
eq(row._width, reserved, "...in the room already reserved")
eq(placed, 0, "...so nothing is placed again")
eq(writes, 0, "...and nothing written")
-- Progress moving on rewrites only the text.
countWrites()
specs = { spec(name, "enemy", { progress = "0/8", progressMax = "8/8" }) }
T.RefreshTargetFrame()
local w0 = row._width
specs = { spec(name, "enemy", { progress = "1/8", progressMax = "8/8" }) }
T.RefreshTargetFrame()
eq(writes, 0, "0/8 -> 1/8 writes no attribute")
eq(row.progress:GetText(), "1/8", "...and shows 1/8")
eq(row._width, w0, "...in the same place")
stopCounting()

------------------------------------------------------------
-- Faces in the lists: the cache's face follows the icon; first seen in combat
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate5", { name = "Bloodscalp Scout", guid = "Creature-0-0-0-0-55-1", plate = true })
specs = { spec("Bloodscalp Scout", "enemy", { unit = "nameplate5" }), spec("Bloodscalp Mystic", "enemy") }
T.RefreshTargetFrame()
local scout, mystic = buttonOf("Bloodscalp Scout"), buttonOf("Bloodscalp Mystic")
local face = scout.portrait
check(face and face.portrait == "nameplate5" and face._shown, "a seen row: its face")
eq(anchor(face)[1] .. tostring(anchor(face)[2] == scout.icon), "ALLtrue", "over the row's picture")
check(not scout.placeholder._shown, "...no placeholder")
check(mystic.placeholder._shown, "an unseen one: the placeholder")

-- The mystic comes into sight mid-fight: its face on its icon at once.
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
WoW.blocked = {}
WoW.SetUnit("nameplate6", { name = "Bloodscalp Mystic", guid = "Creature-0-0-0-0-56-1", plate = true })
specs = { spec("Bloodscalp Scout", "enemy", { unit = "nameplate5" }),
          spec("Bloodscalp Mystic", "enemy", { unit = "nameplate6" }) }
T.CacheFace("Bloodscalp Mystic", "nameplate6")
eq(mystic.icon.portrait, "nameplate6", "first seen in combat: the face on the row's picture")
check(mystic.icon._shown and not mystic.placeholder._shown, "...the placeholder gone")
eq(#WoW.blocked, 0, "...and no protected call refused")
WoW.units["nameplate6"] = nil
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(mystic.portrait and mystic.portrait.portrait == "nameplate6", "after combat: the cached face, attached")

-- Back to Icons: the faces stay, the regions go back.
countWrites()
SlashCmdList.STAKEOUT("layout icons")
eq(writes, 0, "List -> Icons writes no attribute")
eq(scout._width .. "x" .. scout._height, "26x26", "back to 26 px")
check(scout.portrait == face and face._shown, "the cached face is kept")
eq(anchor(face)[2], scout.icon, "...over the icon")
check(scout.label._shown and not scout.nameText._shown and not scout.backing._shown, "labels back, rows' regions gone")
eq(shownHeaders(), "", "no group titles")
stopCounting()
-- A reused button for a name with no face: the chosen icon, shown and plain.
specs = {}
-- Detected without a sighting that could draw its face (a sighting caches it).
SlashCmdList.STAKEOUT("add Uncached Rare")
for k in pairs(detected) do detected[k] = nil end
detected["Uncached Rare"] = { plates = {}, guids = {}, lastSeen = GetTime() }
T.RefreshTargetFrame()
check(buttonOf("Uncached Rare") == scout, "the uncached name reuses the pictured button")
local un = buttonOf("Uncached Rare")
check(un.icon._shown and not un.placeholder._shown, "icons: an uncached name shows the chosen icon")
eq(un.icon._vertex, nil, "...untinted")
-- Then seen, out of combat: a repeat sighting refreshes no button, so the face
-- goes on at once (Codex on #88).
WoW.SetUnit("nameplate7", { name = "Uncached Rare", guid = "Creature-0-0-0-0-57-1", plate = true })
T.CacheFace("Uncached Rare", "nameplate7")
check(un.portrait and un.portrait.portrait == "nameplate7" and un.portrait._shown,
    "a sighting out of combat: its face on the button at once")
check(not un.icon._shown, "...over the icon")
WoW.units["nameplate7"] = nil
SlashCmdList.STAKEOUT("remove Uncached Rare")
SlashCmdList.STAKEOUT("remove Watched Rare")
SlashCmdList.STAKEOUT("remove Second Rare")

------------------------------------------------------------
-- Combat: a switch waits; with a macro change, both come after
------------------------------------------------------------
clean()
specs = { spec("Murloc Raider", "enemy", { macrotext2 = "/cleartarget\n/targetexact Murloc Raider" }),
          spec("Murloc Oracle", "enemy") }
T.RefreshTargetFrame()
local raider = buttonOf("Murloc Raider")
eq(raider:GetAttribute("type2"), "macro", "a right-click macro to begin with")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
WoW.blocked = {}
countWrites()
SlashCmdList.STAKEOUT("layout list")
check(WoW.chatText():find("applies when combat ends", 1, true), "in combat the switch says it waits")
specs = { spec("Murloc Raider", "enemy"), spec("Murloc Oracle", "enemy") }
T.RefreshTargetFrame()
eq(raider._width, 26, "nothing moves in combat")
eq(writes, 0, "...and nothing is written")
eq(#WoW.blocked, 0, "...and no protected call refused (" .. table.concat(WoW.blocked, ", ") .. ")")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(writes > 0, "combat's end writes the macro change")
eq(raider:GetAttribute("type2"), nil, "...type2 cleared")
eq(raider._height, T.ROW_H, "...and the rows are placed")
stopCounting()

------------------------------------------------------------
-- The target's outline, both layouts
------------------------------------------------------------
local function ringOn(btn) return btn.ring[1]._shown and btn.ring[4]._shown end
local function ringsOn()
    local n = 0
    for _, b in ipairs(T.buttons) do if b.ring[1]._shown then n = n + 1 end end
    return n
end
clean()
specs = { spec("Murloc Raider", "enemy"), spec("Murloc Oracle", "enemy") }
T.RefreshTargetFrame()
WoW.SetUnit("target", { name = "Murloc Oracle", guid = "Creature-0-0-0-0-77-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
check(ringOn(buttonOf("Murloc Oracle")), "the target's row: outlined")
eq(ringsOn(), 1, "...and no other")
-- In combat, with a reordered layout pending: the ring follows what each
-- button still clicks.
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
WoW.blocked = {}
specs = { spec("Murloc Oracle", "enemy"), spec("Aardvark Raider", "enemy"), spec("Murloc Raider", "enemy") }
T.RefreshTargetFrame()
WoW.SetUnit("target", { name = "Murloc Raider", guid = "Creature-0-0-0-0-78-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
local mr = buttonOf("Murloc Raider")
check(mr and ringOn(mr), "a new target in combat: the button that clicks it")
eq(ringsOn(), 1, "...only that one")
-- It dies, combat goes on: the outline goes.
WoW.units.target.dead = true
WoW.fire("UNIT_DIED", "Creature-0-0-0-0-78-1")
eq(ringsOn(), 0, "the target dies mid-fight: no outline")
eq(#WoW.blocked, 0, "the outline in combat: no protected call refused")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
-- A name that resolves late.
WoW.SetUnit("target", { name = "Unknown", guid = "Creature-0-0-0-0-79-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
eq(ringsOn(), 0, "Unknown: no outline")
WoW.units.target.name = "Murloc Oracle"
WoW.fire("UNIT_NAME_UPDATE", "target")
check(ringOn(buttonOf("Murloc Oracle")), "its real name arrives: outlined")
WoW.units.target = nil
WoW.fire("PLAYER_TARGET_CHANGED")
eq(ringsOn(), 0, "no target: no outline")
SlashCmdList.STAKEOUT("layout icons")
WoW.SetUnit("target", { name = "Murloc Oracle", guid = "Creature-0-0-0-0-77-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
check(ringOn(buttonOf("Murloc Oracle")), "icons: outlined too")
WoW.units.target = nil
WoW.fire("PLAYER_TARGET_CHANGED")

------------------------------------------------------------
-- A long list at a large scale stays on the screen (Codex on #88)
------------------------------------------------------------
clean()
SlashCmdList.STAKEOUT("layout list")
local uw, uh = UIParent._width, UIParent._height
UIParent:SetSize(1024, 768)
StakeoutDB.frameScale = 3
local tf = T.frame()
T.FitScale()
eq(tf:GetScale(), 3, "the chosen scale")
-- Where the player put it, in screen units: 300, 1500 at 300%.
tf:ClearAllPoints()
tf:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 100, 500)
local function onScreen()
    local _, _, _, x, y = tf:GetPoint()
    return math.floor(x * tf:GetScale() + 0.5) .. "," .. math.floor(y * tf:GetScale() + 0.5)
end
specs = {}
for i = 1, 12 do specs[i] = spec("Murloc Number " .. string.char(64 + i), "enemy") end
T.RefreshTargetFrame()
check(tf:GetScale() < 3, "12 rows at 300%: below the chosen scale")
check(tf:GetHeight() * tf:GetScale() <= 768 + 0.01, "...so the whole list fits the screen's height")
eq(onScreen(), "300,1500", "...and it stays where it was on the screen")
-- Dragged while fitted: the scale its offsets are in is saved with them.
tf._scripts.OnMouseDown(tf, "LeftButton")
tf._scripts.OnMouseUp(tf, "LeftButton")
eq(StakeoutDB.framePos[5], tf:GetScale(), "a drag saves the scale its offsets are in")
specs = { spec("Murloc Number A", "enemy") }
T.RefreshTargetFrame()
eq(tf:GetScale(), 3, "a short list: the chosen scale")
eq(onScreen(), "300,1500", "...in the same place")
-- The list grows during a drag: it fits when the drag ends.
tf._scripts.OnMouseDown(tf, "LeftButton")
specs = {}
for i = 1, 12 do specs[i] = spec("Murloc Number " .. string.char(64 + i), "enemy") end
T.RefreshTargetFrame()
eq(tf:GetScale(), 3, "a drag in progress: the scale waits")
tf._scripts.OnMouseUp(tf, "LeftButton")
check(tf:GetHeight() * tf:GetScale() <= 768 + 0.01, "...and fits when it ends")
specs = { spec("Murloc Number A", "enemy") }
T.RefreshTargetFrame()
StakeoutDB.framePos = nil
UIParent:SetSize(100, 100)
WoW.fire("DISPLAY_SIZE_CHANGED")
check(tf:GetWidth() * tf:GetScale() <= 100 + 0.01, "a smaller screen: scaled to fit it")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
UIParent._width, UIParent._height = 1024, 768   -- the screen changes (UIParent is protected in combat)
WoW.fire("UI_SCALE_CHANGED")
check(tf:GetScale() < 3, "in combat: the scale waits")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
eq(tf:GetScale(), 3, "...and comes back when combat ends")
UIParent._width, UIParent._height = uw, uh
StakeoutDB.frameScale = 1
T.FitScale()

------------------------------------------------------------
-- No buttons hides the frame, in the lists too
------------------------------------------------------------
SlashCmdList.STAKEOUT("layout list2")
clean()
eq(T.frame()._shown, false, "no buttons: the frame is hidden")

done("test_layout")
