------------------------------------------------------------
-- test_customize.lua - #98: the Customize panel beside the settings window,
-- its preview of the buttons, and what the buttons and their tooltips show.
-- The preview draws plain buttons through the target frame's own functions
-- (ns.looks), from fixed samples, and never touches the target frame; each
-- part's setting reaches the target frame at its next render, out of combat.
-- A fake ns.quests gives the quest rows, as in test_layout.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T, ns = WoW.loadAddon()
local detected = T.detected
local L, C = ns.looks, ns.customize

local specs, tokens = {}, {}
ns.quests = {
    OnUnit = function() end, OnPlateRemoved = function() end, OnUnitDied = function() end, Tick = function() end,
    ButtonSpecs = function() return specs end,
    AlertOn = function() return false end,
    TokenFor = function(name) return tokens[name] end,
}
-- A fixed distance: 25-30 yd for whichever unit is asked.
ns.range.Get = function() return 25, 30 end

local function spec(name, row, extra)
    local s = { name = name, row = row, macrotext = "/cleartarget\n/targetexact " .. name }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local PARTS = { "showPortraits", "showNames", "showProgress", "showLabels", "showDistance",
                "tipDistance", "tipProgress", "tipClicks" }
local function defaults()
    for _, k in ipairs(PARTS) do StakeoutDB[k] = nil end
    StakeoutDB.showDistance = false
    StakeoutDB.layout = "icons"
end

local function clean()
    for k in pairs(detected) do detected[k] = nil end
    for k in pairs(T.announced) do T.announced[k] = nil end
    WoW.units, WoW.sounds, WoW.chat, WoW.combat = {}, {}, {}, false
    specs, tokens = {}, {}
    defaults()
    T.RefreshTargetFrame()
end

local function buttonOf(name)
    for _, b in ipairs(T.buttons) do if b._shown and b.npcName == name then return b end end
end
local function tipOf(btn)
    btn._scripts.OnEnter(btn)
    local s = table.concat(GameTooltip._lines or {}, "|")
    btn._scripts.OnLeave(btn)
    return s
end
local function writesDuring(fn)
    local writes = 0
    for _, b in ipairs(T.buttons) do
        local real = getmetatable(b).__index.SetAttribute
        b.SetAttribute = function(self, k, v) writes = writes + 1 return real(self, k, v) end
    end
    fn()
    for _, b in ipairs(T.buttons) do b.SetAttribute = nil end
    return writes
end

------------------------------------------------------------
-- The panel
------------------------------------------------------------
clean()
SlashCmdList.STAKEOUT("config")
local cfg, panel = StakeoutConfigFrame, StakeoutCustomizeFrame
check(panel ~= nil and panel:GetParent() == cfg, "the Customize panel is built with the settings, as their child")
check(not panel:IsShown(), "...hidden until asked for")
check(cfg.layoutDropdown and StakeoutScaleSlider and cfg.iconPicker, "Layout, Scale and Button icon exist with it")
check(StakeoutScaleSlider:GetParent() == panel and cfg.layoutDropdown:GetParent() == panel,
    "...on the panel, moved from the settings' right column")
cfg.customizeButton._scripts.OnClick(cfg.customizeButton)
check(panel:IsShown(), "the settings' Customize buttons... opens it")
cfg:Hide()
check(not panel:IsVisible(), "it hides with the settings")
cfg:Show()
cfg.customizeButton._scripts.OnClick(cfg.customizeButton)
check(not panel:IsShown(), "...and the button closes it again")
C.Toggle()

-- The preview: plain buttons, the four samples, drawn as the real ones.
local pv = C._test.buttons
eq(#pv, 4, "four sample buttons")
for i, b in ipairs(pv) do
    check(b._template == nil and b:GetAttribute("type") == nil, "sample " .. i .. " is a plain button, no secure action")
end
eq(pv[1].npcName, "Mor'Ladim", "the watch rare")
eq(pv[2].npcName, "Cook Torka", "the NPC to turn in to")
check(pv[3].bell._shown, "the quest mob wears the alert mark")
check(pv[3].ring[1]._shown, "...and the target outline")
check(not pv[3].dist._shown, "no distance on the buttons by default")
SlashCmdList.STAKEOUT("layout list")
eq(pv[3].progress._text, "3/10", "a list: the sample's progress")
check(pv[3].nameText._shown and pv[4].nameText._text == "Kobold Laborer", "...and names")
check(C.stage.groupHeaders and C.stage.groupHeaders[1]._shown, "...under its own group titles, on its own box")
pv[3]._scripts.OnEnter(pv[3])
local tip = table.concat(GameTooltip._lines or {}, "|")
pv[3]._scripts.OnLeave(pv[3])
check(tip:find("Distance: 25-30 yd", 1, true) and tip:find("Alert on (Shift+right-click to stop)", 1, true),
    "a sample's tooltip by the live rules: " .. tip)
-- Its click hints follow the marking setting, as the live ones do.
StakeoutDB.enableMarking = false
pv[1]._scripts.OnEnter(pv[1])
tip = table.concat(GameTooltip._lines or {}, "|")
pv[1]._scripts.OnLeave(pv[1])
check(tip:find("Left-click: target", 1, true) and not tip:find("mark", 1, true), "marking off: no mark promised: " .. tip)
StakeoutDB.enableMarking = true
SlashCmdList.STAKEOUT("layout icons")

-- In combat: the preview redraws, the target frame isn't touched.
specs = { spec("Mob A", "enemy", { progress = "1/5", progressMax = "5/5" }) }
T.RefreshTargetFrame()
local tf = T.frame()
local regionsBefore, headsBefore = #tf._regions, tf.groupHeaders and #tf.groupHeaders or 0
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
local writes = writesDuring(function()
    SlashCmdList.STAKEOUT("layout list")
    C.boxes.showNames._scripts.OnClick(C.boxes.showNames)
end)
eq(writes, 0, "in combat: a change writes no attribute")
eq(#tf._regions, regionsBefore, "...creates no region on the target frame (the preview measures elsewhere)")
check(L.measureHost ~= nil and L.measureHost ~= tf, "text is measured on a plain frame of its own")
eq(tf.groupHeaders and #tf.groupHeaders or 0, headsBefore, "...nor a group title there")
check(not pv[3].nameText._shown, "...while the preview shows the change at once")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
StakeoutDB.showNames = nil
SlashCmdList.STAKEOUT("layout icons")

------------------------------------------------------------
-- Each part on the real buttons
------------------------------------------------------------
clean()
specs = {
    spec("Kobold Laborer", "enemy", { progress = "3/10", progressMax = "10/10",
        tooltip = { "Kobolds: 3/10 Kobold Laborer slain" }, clicks = { "Left-click: target" } }),
    spec("Cook Torka", "friendly", { progress = "turn in", progressMax = "turn in", clicks = { "Left-click: target" } }),
}
SlashCmdList.STAKEOUT("layout list")
local kl = buttonOf("Kobold Laborer")
check(kl.nameText._shown and kl.progress._shown, "a list row: name and progress by default")
local wide = kl._width
StakeoutDB.showNames = false
T.RefreshTargetFrame()
check(not kl.nameText._shown, "Names off: no name")
check(kl._width < wide, ("...and the row narrows (%d < %d)"):format(kl._width, wide))
StakeoutDB.showProgress = false
T.RefreshTargetFrame()
check(not kl.progress._shown, "Progress off: no status")
-- Names on, Progress and Distance off: the name reaches the row's edge (a
-- hidden status can't take its room).
StakeoutDB.showNames = nil
T.RefreshTargetFrame()
local np = kl.nameText._points
local right
for _, p in ipairs(np) do if p[1] == "RIGHT" then right = p end end
check(right and right[2] == kl, "names on, progress and distance off: the name anchors to the row itself")
StakeoutDB.showNames = false
T.RefreshTargetFrame()
-- The compact list keeps its titles inside (Codex on the plan).
local f = T.frame()
local widest = 0
for _, h in ipairs(f.groupHeaders or {}) do
    if h._shown then widest = math.max(widest, h:GetStringWidth()) end
end
check(f._width >= widest + 2 * L.ROW_PAD, ("a compact list keeps its group titles inside (%d >= %d)"):format(f._width,
    widest + 2 * L.ROW_PAD))
StakeoutDB.showNames, StakeoutDB.showProgress = nil, nil
SlashCmdList.STAKEOUT("layout icons")
T.RefreshTargetFrame()
check(kl.label._shown, "icons: the label under a quest button")
local tall = f._height
StakeoutDB.showLabels = false
T.RefreshTargetFrame()
check(not kl.label._shown, "Labels off: none")
check(f._height < tall, "...and the quest line is shorter")
StakeoutDB.showLabels = nil
T.RefreshTargetFrame()

-- Tooltip lines: each part on its own; state always.
local t = tipOf(kl)
check(t:find("3/10 Kobold Laborer", 1, true) and t:find("Left-click: target", 1, true)
    and t:find("Shift+right-click: alert", 1, true), "the tooltip: progress, clicks, the alert hint")
StakeoutDB.tipProgress = false
t = tipOf(kl)
check(not t:find("3/10 Kobold Laborer", 1, true) and t:find("Left-click: target", 1, true), "Quest progress off")
StakeoutDB.tipProgress, StakeoutDB.tipClicks = nil, false
t = tipOf(kl)
check(t:find("3/10 Kobold Laborer", 1, true) and not t:find("Left-click", 1, true)
    and not t:find("Shift+right-click", 1, true), "Click hints off: no hint at all")
StakeoutDB.tipClicks = nil
-- An armed hunt button with progress shown and clicks hidden: its state, no instruction.
specs[1].hunt = true
specs[1].tooltip = { "Not seen yet" }
specs[1].clicks = { "Click to look for one", "Left-click: target" }
ns.quests.AlertOn = function(name) return name == "Kobold Laborer" end
T.RefreshTargetFrame()
StakeoutDB.tipClicks = false
t = tipOf(buttonOf("Kobold Laborer"))
check(t:find("Not seen yet", 1, true) and t:find("Alert on", 1, true) and not t:find("click", 1, true)
    and not t:find("Shift", 1, true), "an armed hunt button, clicks hidden: \"Alert on\", \"Not seen yet\", no instruction: " .. t)
StakeoutDB.tipProgress = false
t = tipOf(buttonOf("Kobold Laborer"))
check(t:find("Alert on", 1, true) and not t:find("Not seen yet", 1, true) and not t:find("Shift", 1, true),
    "progress and clicks hidden: \"Not seen yet\" is a quest line and goes, \"Alert on\" stays: " .. t)
StakeoutDB.tipClicks, StakeoutDB.tipProgress = nil, nil
ns.quests.AlertOn = function() return false end

------------------------------------------------------------
-- The distance
------------------------------------------------------------
clean()
SlashCmdList.STAKEOUT("add Rare Mob")
WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-0-1-2-3-99-A", attackable = true })
WoW.fire("PLAYER_TARGET_CHANGED")
local rare = buttonOf("Rare Mob")
eq(rare.unit, "target", "a watch button first drawn from the target")
StakeoutDB.showDistance = true
T.RefreshTargetFrame()
check(rare.dist._shown, "Distance on: the button shows one")
eq(rare.dist._text, "30", "...short, on an icon")
-- Kept targeted while a plate comes and goes: from the target (its last
-- token was the plate, now gone).
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-0-1-2-3-99-A", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
rare.dist:SetText("")
L.driver._scripts.OnUpdate(L.driver, 1)
eq(rare.dist._text, "30", "plate gone, still targeted: from the target")
-- On a plate, last seen as the target, then the player targets something
-- else: from its plate, not the stale target token.
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-0-1-2-3-99-A", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.fire("PLAYER_TARGET_CHANGED")   -- still the Rare Mob: its last token is "target"
eq(detected["Rare Mob"].unitId, "target", "(its last token is the target)")
WoW.SetUnit("target", { name = "Someone Else", guid = "Creature-0-1-2-3-77-B" })
WoW.fire("PLAYER_TARGET_CHANGED")
rare.dist:SetText("")
L.driver._scripts.OnUpdate(L.driver, 1)
eq(rare.dist._text, "30", "the target changed: read from its plate")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-0-1-2-3-99-A", attackable = true })
WoW.fire("PLAYER_TARGET_CHANGED")
SlashCmdList.STAKEOUT("layout list")
L.driver._scripts.OnUpdate(L.driver, 1)
eq(rare.dist._text, "30 yd", "a list: with its unit")
-- A quest button: from any token its members hold (Quests.lua's TokenFor).
specs = { spec("Kobold Laborer", "enemy"), spec("Kobold Worker", "enemy", { hunt = true }) }
WoW.SetUnit("nameplate2", { name = "Kobold Laborer", guid = "Creature-0-1-2-3-55-A", plate = true })
tokens["Kobold Laborer"] = "nameplate2"
T.RefreshTargetFrame()
L.driver._scripts.OnUpdate(L.driver, 1)
eq(buttonOf("Kobold Laborer").dist._text, "30 yd", "a quest button: from its member's token")
eq(buttonOf("Kobold Worker").dist._text, "", "a hunt button with no token: blank")
-- In combat: text only; turned off in combat it keeps updating until the
-- fight ends (the live frame still shows it), then hides.
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
StakeoutDB.showDistance = false
T.RefreshTargetFrame()
local lab = buttonOf("Kobold Laborer")
check(lab.dist._shown, "Distance off in combat: still shown until the fight ends")
ns.range.Get = function() return 0, 8 end
L.driver._scripts.OnUpdate(L.driver, 1)
eq(lab.dist._text, "8 yd", "...and still updated (never a stale number)")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(not lab.dist._shown, "the fight over: hidden")
ns.range.Get = function() return 25, 30 end
-- A button reused for another NPC shows that one's distance at once, even
-- while the old one is still in sight.
clean()
local byUnit = { nameplate1 = { 0, 8 }, nameplate2 = { 25, 30 } }
ns.range.Get = function(u) local r = byUnit[u] if r then return r[1], r[2] end end
StakeoutDB.showDistance = true
WoW.SetUnit("nameplate1", { name = "Aaa Mob", guid = "Creature-0-1-2-3-11-A", plate = true })
WoW.SetUnit("nameplate2", { name = "Bbb Mob", guid = "Creature-0-1-2-3-12-A", plate = true })
tokens["Aaa Mob"], tokens["Bbb Mob"] = "nameplate1", "nameplate2"
specs = { spec("Aaa Mob", "enemy"), spec("Bbb Mob", "enemy") }
T.RefreshTargetFrame()
eq(T.buttons[1].npcName, "Aaa Mob", "button 1: the first name")
eq(T.buttons[1].dist._text, "8", "...its distance")
specs = { spec("Bbb Mob", "enemy") }
T.RefreshTargetFrame()
eq(T.buttons[1].npcName, "Bbb Mob", "button 1 now shows the other NPC")
eq(T.buttons[1].dist._text, "30", "...with its distance at once, never the old one's")
ns.range.Get = function() return 25, 30 end
StakeoutDB.showDistance = false
-- Range.Short at the brackets' edges.
local R = ns.range
eq(R.ShortOf(0, 8), "8", "within 8 yd: 8")
eq(R.ShortOf(25, 30), "30", "25-30 yd: 30")
eq(R.ShortOf(40, math.huge), "40+", "over 40 yd: 40+")
eq(R.ShortOf(nil), nil, "nothing answered: none")
SlashCmdList.STAKEOUT("layout icons")

------------------------------------------------------------
-- Portraits off
------------------------------------------------------------
clean()
SlashCmdList.STAKEOUT("add Rare Mob")
StakeoutDB.showPortraits = false
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-0-1-2-3-99-A", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
rare = buttonOf("Rare Mob")
check(rare.portrait == nil and rare.icon._shown, "Portraits off: the icon, never a face")
-- A repeat sighting (CacheFace's own path) puts none on it either.
WoW.SetUnit("nameplate2", { name = "Rare Mob", guid = "Creature-0-1-2-3-99-B", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
check(rare.portrait == nil, "...a repeat sighting adds none")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
rare.icon.portrait = nil   -- the stub's SetPortraitTexture writes the unit here
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
eq(rare.icon.portrait, nil, "...nor in combat (no face painted on the icon)")
-- Turned on in combat: nothing until the fight ends, then the cached face.
StakeoutDB.showPortraits = true
T.RefreshTargetFrame()
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
eq(rare.icon.portrait, nil, "turned on in combat: no face yet (the live frame still has them off)")
WoW.units = {}
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
check(rare.portrait ~= nil, "the fight over: the cached face, the token gone")
StakeoutDB.showPortraits = nil

------------------------------------------------------------
-- Where the panel goes
------------------------------------------------------------
clean()
local uw, uh = UIParent._width, UIParent._height
UIParent:SetSize(1920, 1080)
if not panel:IsShown() then C.Toggle() end
local pw, cw = panel:GetWidth(), cfg:GetWidth()
cfg._left, cfg._right, cfg._top = 600, 600 + cw, 900
C.Place()
eq(panel.where, "right", "room on the right: there")
cfg._left, cfg._right = 1920 - cw - 10, 1910
C.Place()
eq(panel.where, "left", "no room on the right: on the left")
local sw = cw + pw + 4 + 20
UIParent:SetSize(sw, 1080)
cfg._left = math.floor((sw - cw) / 2)   -- centred: no room on either side
cfg._right = cfg._left + cw
C.Place()
eq(panel.where, "moved", "neither: the settings move so both fit")
UIParent:SetSize(1024, 768)
C.Place()
eq(panel.where, "over", "a 1024-wide screen: over the settings' left column")
local over = panel:GetFrameLevel()
check(over > cfg:GetFrameLevel() + 1, "...above the window's own controls")
-- Closed with the settings and opened again: placed again, still above.
cfg:Hide()
cfg:Show()
panel._scripts.OnShow(panel)
eq(panel:GetFrameLevel(), over, "reopened with the settings: still above them")
-- After the settings are dragged (their OnMouseUp), it's placed again.
UIParent:SetSize(1920, 1080)
cfg._left, cfg._right = 600, 600 + cw
cfg._scripts.OnMouseDown(cfg, "LeftButton")
cfg._scripts.OnMouseUp(cfg, "LeftButton")
eq(panel.where, "right", "the settings dragged: the panel follows")
UIParent._width, UIParent._height = uw, uh

done("test_customize")
