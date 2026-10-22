------------------------------------------------------------
-- test_theme.lua - the windows' look (#28): WoW Forever by default, LibGlass
-- glass when chosen, applied after a /reload.
--
-- What this can't judge is the look itself: whether the glass reads over
-- bright grass or a dark cave is an in-game question. What it does check is
-- that each window was built as the chosen look, with the recipe's values,
-- that the masks belong to the frames they clip, and that the target frame
-- stays the same secure frame: glass built only out of combat, nothing of it
-- taking the mouse.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

-- A session: a fresh event table (a new UI), these saved settings, loaded.
local function session(saved, opts)
    WoW.events = {}
    WoW.messages = {}
    WoW.inCombat = false
    opts = opts or {}
    opts.savedDB = saved
    local T = WoW.loadAddon(opts)
    return T, WoW.ns.theme
end

local function detect(token, name)
    WoW.SetUnit(token, { name = name, guid = "Creature-0-0-0-0-1-" .. token, plate = true })
    WoW.fire("NAME_PLATE_UNIT_ADDED", token)
end

-- Every frame in `root`'s tree, root included.
local function tree(root, out)
    out = out or {}
    out[#out + 1] = root
    for _, c in ipairs(root.children) do
        if c.kind ~= "Texture" and c.kind ~= "FontString" and c.kind ~= "MaskTexture" then tree(c, out) end
    end
    return out
end

local function color(tex) return tex.color and table.concat(tex.color, ",") or "none" end
local function rgba(t) return table.concat(t, ",") end

-- Fire every script handler of every frame (test_frames' sweep), for the
-- glass look this time.
local ARGS = {
    OnClick = { "LeftButton", false }, OnMouseDown = { "LeftButton" }, OnMouseUp = { "LeftButton" },
    OnValueChanged = { 150 },
}
local function fireAll(label)
    local frames = {}
    for i, f in ipairs(WoW.frames) do frames[i] = f end
    local ran = 0
    for _, f in ipairs(frames) do
        for script, fn in pairs(f.scripts) do
            if script ~= "OnEvent" then
                local args = ARGS[script] or {}
                local ok, err = pcall(fn, f, args[1], args[2])
                H.check(ok, label .. ": " .. tostring(f.name or f.kind) .. " " .. script .. " - " .. tostring(err))
                ran = ran + 1
            end
        end
    end
    return ran
end

------------------------------------------------------------
-- The default: the WoW Forever look, exactly the backdrops as before
------------------------------------------------------------
do
    local T, Theme = session({ svLoadCheck = 1 })
    H.eq(StakeoutDB.theme, "forever", "the default look is WoW Forever")
    H.eq(Theme.Active(), "forever", "and that is the one worn")
    local f = T.frame()
    H.check(f.backdrop ~= nil and f.glass == nil, "the target frame has its backdrop, no glass")
    SlashCmdList.STAKEOUT("add Rare Mob")
    detect("nameplate1", "Rare Mob")
    local btn = T.buttons[1]
    H.check(btn and btn.glassPill == nil and #btn.icon.masks == 0, "a target button is the plain square")
    SlashCmdList.STAKEOUT("config")
    SlashCmdList.STAKEOUT("export")
    H.check(StakeoutConfigFrame.backdrop and not StakeoutConfigFrame.glass, "the config window has its backdrop")
    H.check(StakeoutAddBox.backdrop and not StakeoutAddBox.glass, "so does the add box")
    H.check(StakeoutScrollFrame.parent.backdrop and not StakeoutScrollFrame.parent.glassReading,
        "and the list's box")
    H.check(StakeoutExportFrame.backdrop and not StakeoutExportFrame.glass, "the export window has its backdrop")
    H.eq(WoW.chat():find("glass look", 1, true), nil, "nothing said about glass")

    -- Choosing in the config: saved, worn after a /reload.
    local dd = StakeoutLookDropdown
    WoW.dropdownItems = {}
    dd.initFn()
    H.eq(#WoW.dropdownItems, 2, "two looks to choose from")
    H.eq(WoW.dropdownItems[1].text, "WoW Forever", "WoW Forever first")
    H.eq(WoW.dropdownItems[1].checked, true, "and ticked: it is the saved one")
    H.eq(WoW.dropdownItems[2].text, "Glass", "then Glass")
    WoW.messages = {}
    WoW.dropdownItems[2].func()
    H.eq(StakeoutDB.theme, "glass", "the choice is saved")
    H.eq(Theme.Active(), "forever", "the windows keep their look until a /reload")
    H.eq(dd.text, "Glass", "the dropdown shows the choice")
    H.check(WoW.chat():find("/reload", 1, true), "the player is told to /reload")
    WoW.messages = {}
    WoW.dropdownItems[1].func()
    H.eq(StakeoutDB.theme, "forever", "chosen back")
    H.check(WoW.chat():find("the one in use", 1, true), "no /reload asked for the look already worn")

    -- The same from the command line.
    WoW.messages = {}
    SlashCmdList.STAKEOUT("look GLASS")
    H.eq(StakeoutDB.theme, "glass", "/stakeout look glass saves it")
    H.check(WoW.chat():find("/reload", 1, true), "and asks for the /reload")
    WoW.messages = {}
    SlashCmdList.STAKEOUT("look chrome")
    H.eq(StakeoutDB.theme, "glass", "an unknown look changes nothing")
    H.check(WoW.chat():find("Look: WoW Forever.", 1, true), "it says the look worn, and the choices")
    SlashCmdList.STAKEOUT("look forever")
    H.eq(StakeoutDB.theme, "forever", "/stakeout look forever")
end

------------------------------------------------------------
-- Glass
------------------------------------------------------------
local T, Theme = session({ svLoadCheck = 1, theme = "glass" })
H.eq(Theme.Active(), "glass", "a saved glass choice is worn at the next load")
local Glass = Theme._test.Glass()
-- LibGlass names its textures under the addon it is embedded in: loaded
-- under any other name, every layer would draw nothing, with no error.
H.eq(Glass.MEDIA, "Interface\\AddOns\\Stakeout\\Libs\\LibGlass-1.0\\Media\\",
    "the library's textures are Stakeout's embedded copy")
H.eq(Glass.STYLE.thinRim, true, "the clean preset: thin rims")
H.eq(WoW.chat():find("glass look", 1, true), nil, "nothing to report when glass loads")

local SHELL, CONTROL = Theme._test.SHELL, Theme._test.CONTROL

-- The target frame: the small shell, lit over its 16 px header.
local f = T.frame()
local g = f.glass
H.check(g ~= nil and f.backdrop == nil, "the target frame wears glass, not its backdrop")
H.eq(g.size, "thin_small", "the small rim: the frame can be one button high")
H.eq(color(g.tint), rgba(SHELL.tint), "the shell's tint")
H.eq(color(g.backing), rgba(SHELL.backing), "the shell's backing")
H.eq(g.backing.masks[1], g.mask, "the backing is cut to the shell's rounded shape")
H.eq(g.backing.owner, f, "by a mask on its own frame")
H.eq(g.backing.sublevel, -7, "between the library's shadow (-8) and tint (-6)")
H.eq(g.rim.alpha, SHELL.rim, "the faint base rim")
H.eq(g.dark.alpha, SHELL.dark, "the dark rim")
H.eq(g.grain.alpha, 0, "no grain")
H.check(g.reflect and g.reflect.rim and g.reflect.top, "the lit rim and top highlight")
H.eq(g.reflect.header and g.reflect.header.height, 16, "the header reflection fits the title row")
H.eq(g.edge.top.shown, false, "no edge: the top highlight takes its place")

-- Buttons: a pill under each, the picture inset and rounded.
SlashCmdList.STAKEOUT("add Rare Mob; Other Mob")
detect("nameplate1", "Rare Mob")
local btn = T.buttons[1]
H.eq(btn.template, "SecureActionButtonTemplate", "the button is still the secure button")
H.eq(btn:GetAttribute("macrotext"), "/cleartarget\n/targetexact Rare Mob\n/cleartarget [dead]", "with its macro")
H.eq(table.concat(btn.clicks, ","), "AnyUp,AnyDown", "and both click edges")
local pill = btn.glassPill
H.check(pill and pill.parent == btn, "a glass pill on the button")
H.eq(pill.level, btn.level - 1, "under the button, so its rims stay under the picture")
H.eq(color(pill.glassPill.tint), rgba(CONTROL.tint), "the control's tint")
H.eq(pill.glassPill.shadow.alpha, 0, "no shadow spilling onto the next button")
for _, tex in ipairs({ btn.icon, btn.highlight }) do
    H.eq(#tex.masks, 1, "the picture and highlight are rounded")
    H.eq(tex.masks[1].owner, btn, "by a mask the button owns")
    local p = tex.points[#tex.points]
    H.eq(p and p[1] .. p[4] .. p[5], "BOTTOMRIGHT-22", "inset 2 px so the rim shows")
end

-- Nothing glass builds on the target frame takes the mouse: clicks reach the
-- secure buttons, and the frame's own drag stays the frame's.
for _, w in ipairs(tree(f)) do
    if w ~= f and w.template ~= "SecureActionButtonTemplate" then
        H.check(not w.mouse, "a glass frame never takes the mouse")
    end
end

-- In combat a new detection builds nothing on the protected frame (the stub
-- throws on any secure write); the button and its glass come after combat.
WoW.inCombat = true
WoW.fire("PLAYER_REGEN_DISABLED")
detect("nameplate2", "Other Mob")
H.eq(#T.buttons, 1, "no button made in combat")
H.eq(T.pendingRefresh(), true, "the layout waits for combat to end")
-- The plain windows open in combat, glass and all, the first time.
SlashCmdList.STAKEOUT("config")
SlashCmdList.STAKEOUT("export")
H.check(StakeoutConfigFrame.glass, "the config window opens in glass in combat")
H.check(StakeoutExportFrame.glass, "the export window too")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(#T.buttons, 2, "the second button is made when combat ends")
H.check(T.buttons[2].glassPill ~= nil, "with its glass")
-- Sorted by name: the new one takes the first button, the old one moves on.
H.eq(T.buttons[1]:GetAttribute("macrotext"), "/cleartarget\n/targetexact Other Mob\n/cleartarget [dead]",
    "the new name's macro")
H.eq(T.buttons[2]:GetAttribute("macrotext"), "/cleartarget\n/targetexact Rare Mob\n/cleartarget [dead]",
    "and the first one's")

-- The config window: the large shell, a reading region under the list, the
-- add box a control.
local cg = StakeoutConfigFrame.glass
H.eq(cg.size, "thin", "the config window: the large shell")
H.eq(cg.reflect.header.height, 40, "lit down to the rule under its title")
H.eq(StakeoutConfigFrame.backdrop, nil, "no backdrop under the glass")
H.eq(StakeoutAddBox.glass and StakeoutAddBox.glass.size, "thin_small", "the add box is a glass control")
H.eq(color(StakeoutAddBox.glass.tint), rgba(CONTROL.tint), "with the control's tint")
local list = StakeoutScrollFrame.parent
local pane = list.glassReading
H.check(pane and list.backdrop == nil, "the list sits on a reading region, not a backdrop")
H.eq(color(pane), rgba(Theme._test.READING), "the reading region's colour")
H.eq(pane.masks[1].owner, list, "masked by its own frame")
H.eq(pane.masks[1].points[1][2], pane, "to its own rounded shape")

local eg = StakeoutExportFrame.glass
H.eq(eg.reflect.header.height, 22, "the export window, lit down to its text")
H.check(StakeoutExportFrame.glassReading, "its text sits on a reading region")
H.eq(StakeoutExportFrame.glassReading.points[1][2], StakeoutExportScroll, "covering the text's scroll area")
-- The pane shares the export window with its shell: it must draw over every
-- layer of it, or the shell's tint covers the text's backing (Codex on #29).
local over = true
for _, c in ipairs(StakeoutExportFrame.children) do
    if c ~= StakeoutExportFrame.glassReading and c.layer == "BACKGROUND"
        and (c.sublevel or 0) >= StakeoutExportFrame.glassReading.sublevel then
        over = false
    end
end
H.check(over, "the export's reading region draws over its window's shell")

-- Last: the sweep clicks Clear All, Reset Detections and every delete.
H.check(fireAll("glass, out of combat") > 40, "every handler runs under glass")
WoW.inCombat = true
H.check(fireAll("glass, in combat") > 40, "and in combat")
WoW.inCombat = false

------------------------------------------------------------
-- A saved value that isn't a look is the default
------------------------------------------------------------
do
    local T2, Theme2 = session({ svLoadCheck = 1, theme = "chrome" })
    H.eq(Theme2.Active(), "forever", "an unknown look is WoW Forever")
    H.check(T2.frame().backdrop ~= nil, "with its backdrop")
    H.eq(WoW.chat():find("glass look", 1, true), nil, "and nothing said")
end

------------------------------------------------------------
-- No library: the WoW Forever look, and the player is told
------------------------------------------------------------
do
    rawset(_G, "LibStub", nil)
    local T3, Theme3 = session({ svLoadCheck = 1, theme = "glass" }, { noLibrary = true })
    H.eq(Theme3.Active(), "forever", "without LibGlass, WoW Forever")
    H.check(T3.frame().backdrop ~= nil, "the frame has its backdrop")
    H.check(WoW.chat():find("glass look isn't available (LibGlass-1.0 isn't loaded)", 1, true),
        "the player is told why")
    H.eq(StakeoutDB.theme, "glass", "and the choice is kept for when the library is back")
    SlashCmdList.STAKEOUT("add Rare Mob")
    detect("nameplate1", "Rare Mob")
    H.check(T3.buttons[1] and T3.buttons[1].glassPill == nil, "buttons are plain")
end

H.done("test_theme")
