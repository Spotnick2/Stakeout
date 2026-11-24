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
    WoW.dropEvents()
    WoW.chat = {}
    WoW.combat = false
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
    for _, c in ipairs(root._children) do
        if c._type ~= "Texture" and c._type ~= "FontString" and c._type ~= "MaskTexture" then tree(c, out) end
    end
    return out
end

local function color(tex) return tex._color and table.concat(tex._color, ",") or "none" end
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
        for script, fn in pairs(f._scripts) do
            if script ~= "OnEvent" then
                local args = ARGS[script] or {}
                local ok, err = pcall(fn, f, args[1], args[2])
                check(ok, label .. ": " .. tostring(f._name or f._type) .. " " .. script .. " - " .. tostring(err))
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
    eq(StakeoutDB.theme, "forever", "the default look is WoW Forever")
    eq(Theme.Active(), "forever", "and that is the one worn")
    local f = T.frame()
    check(f._backdrop ~= nil and f.glass == nil, "the target frame has its backdrop, no glass")
    SlashCmdList.STAKEOUT("add Rare Mob")
    detect("nameplate1", "Rare Mob")
    local btn = T.buttons[1]
    check(btn and btn.glassPill == nil and #(btn.icon._masks or {}) == 0, "a target button is the plain square")
    SlashCmdList.STAKEOUT("config")
    SlashCmdList.STAKEOUT("export")
    check(StakeoutConfigFrame._backdrop and not StakeoutConfigFrame.glass, "the config window has its backdrop")
    check(StakeoutAddBox._backdrop and not StakeoutAddBox.glass, "so does the add box")
    check(StakeoutScrollFrame._parent._backdrop and not StakeoutScrollFrame._parent.glassReading,
        "and the list's box")
    check(StakeoutExportFrame._backdrop and not StakeoutExportFrame.glass, "the export window has its backdrop")
    eq(WoW.chatText():find("glass look", 1, true), nil, "nothing said about glass")

    -- Choosing in the config: saved, worn after a /reload.
    local dd = StakeoutLookDropdown
    WoW.dropdownItems = {}
    dd.initFn()
    eq(#WoW.dropdownItems, 2, "two looks to choose from")
    eq(WoW.dropdownItems[1].text, "WoW Forever", "WoW Forever first")
    eq(WoW.dropdownItems[1].checked, true, "and ticked: it is the saved one")
    eq(WoW.dropdownItems[2].text, "Glass", "then Glass")
    WoW.chat = {}
    WoW.dropdownItems[2].func()
    eq(StakeoutDB.theme, "glass", "the choice is saved")
    eq(Theme.Active(), "forever", "the windows keep their look until a /reload")
    eq(dd.text, "Glass", "the dropdown shows the choice")
    check(WoW.chatText():find("/reload", 1, true), "the player is told to /reload")
    WoW.chat = {}
    WoW.dropdownItems[1].func()
    eq(StakeoutDB.theme, "forever", "chosen back")
    check(WoW.chatText():find("the one in use", 1, true), "no /reload asked for the look already worn")

    -- The same from the command line.
    WoW.chat = {}
    SlashCmdList.STAKEOUT("look GLASS")
    eq(StakeoutDB.theme, "glass", "/stakeout look glass saves it")
    check(WoW.chatText():find("/reload", 1, true), "and asks for the /reload")
    WoW.chat = {}
    SlashCmdList.STAKEOUT("look chrome")
    eq(StakeoutDB.theme, "glass", "an unknown look changes nothing")
    check(WoW.chatText():find("Look: WoW Forever.", 1, true), "it says the look worn, and the choices")
    SlashCmdList.STAKEOUT("look forever")
    eq(StakeoutDB.theme, "forever", "/stakeout look forever")
end

------------------------------------------------------------
-- Glass
------------------------------------------------------------
local T, Theme = session({ svLoadCheck = 1, theme = "glass" })
eq(Theme.Active(), "glass", "a saved glass choice is worn at the next load")
local Glass = Theme._test.Glass()
-- LibGlass names its textures under the addon it is embedded in: loaded
-- under any other name, every layer would draw nothing, with no error.
eq(Glass.MEDIA, "Interface\\AddOns\\Stakeout\\Libs\\LibGlass-1.0\\Media\\",
    "the library's textures are Stakeout's embedded copy")
eq(Glass.STYLE.thinRim, true, "the clean preset: thin rims")
eq(WoW.chatText():find("glass look", 1, true), nil, "nothing to report when glass loads")

local SHELL, CONTROL = Theme._test.SHELL, Theme._test.CONTROL

-- The target frame: the small shell, lit over its 16 px header.
local f = T.frame()
local g = f.glass
check(g ~= nil and f._backdrop == nil, "the target frame wears glass, not its backdrop")
eq(g.size, "thin_small", "the small rim: the frame can be one button high")
eq(color(g.tint), rgba(SHELL.tint), "the shell's tint")
eq(color(g.backing), rgba(SHELL.backing), "the shell's backing")
eq(g.backing._masks[1], g.mask, "the backing is cut to the shell's rounded shape")
eq(g.backing._parent, f, "by a mask on its own frame")
eq(g.backing._sublevel, -7, "between the library's shadow (-8) and tint (-6)")
eq(g.rim._alpha, SHELL.rim, "the faint base rim")
eq(g.dark._alpha, SHELL.dark, "the dark rim")
eq(g.grain._alpha, 0, "no grain")
check(g.reflect and g.reflect.rim and g.reflect.top, "the lit rim and top highlight")
eq(g.reflect.header and g.reflect.header._height, 16, "the header reflection fits the title row")
eq(g.edge.top._shown, false, "no edge: the top highlight takes its place")

-- Buttons: a pill under each, the picture inset and rounded.
SlashCmdList.STAKEOUT("add Rare Mob; Other Mob")
detect("nameplate1", "Rare Mob")
local btn = T.buttons[1]
eq(btn._template, "SecureActionButtonTemplate", "the button is still the secure button")
eq(btn:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Rare Mob\n/cleartarget [dead]", "with its macro")
eq(table.concat(btn._forClicks, ","), "AnyUp,AnyDown", "and both click edges")
local pill = btn.glassPill
check(pill and pill._parent == btn, "a glass pill on the button")
eq(pill._level, btn._level - 1, "under the button, so its rims stay under the picture")
eq(color(pill.glassPill.tint), rgba(CONTROL.tint), "the control's tint")
eq(pill.glassPill.shadow._alpha, 0, "no shadow spilling onto the next button")
for _, tex in ipairs({ btn.icon, btn.highlight }) do
    eq(#tex._masks, 1, "the picture and highlight are rounded")
    eq(tex._masks[1]._parent, btn, "by a mask the button owns")
    local p = tex._points[#tex._points]
    eq(p and p[1] .. p[4] .. p[5], "BOTTOMRIGHT-22", "inset 2 px so the rim shows")
end
-- The NPC's face is its own texture, moved onto the button: rounded and inset the same.
local face = btn.portrait
check(face and face._masks and #face._masks == 1 and face._masks[1] == btn.iconMask,
    "a portrait on the button is rounded by the same mask")
-- It follows the picture, wherever a layout puts it (#88): the icon's inset
-- is the face's.
local fp = face and face._points[#face._points]
check(fp and fp[1] == "ALL" and fp[2] == btn.icon, "...and stands over the picture, inset the same")

-- The list layouts (#88): a row's face is a small square at its left, rounded
-- by a mask of its own over the picture; the row-sized mask stays on the
-- highlight and the dark backing, inset so the pill's rim shows.
local function masks(tex)
    local out = {}
    for _, m in ipairs(tex._masks or {}) do out[#out + 1] = m == btn.iconMask and "row" or m == btn.pictureMask and "picture" or "?" end
    return table.concat(out, ",")
end
check(btn.pictureMask and btn.pictureMask._parent == btn, "a picture mask the button owns")
local pm = btn.pictureMask._points[1]
eq(pm and pm[2], btn.icon, "...over the picture, wherever it stands")
eq(masks(btn.placeholder), "picture", "the placeholder wears it")
eq(btn.backing._sublevel, -1, "the backing under the picture (BACKGROUND -1)")
eq(masks(btn.backing), "row", "...rounded like the pill")
local bp = btn.backing._points[#btn.backing._points]
eq(bp and bp[1] .. bp[4] .. bp[5], "BOTTOMRIGHT-22", "...and inset 2 px so the rim shows")
SlashCmdList.STAKEOUT("layout list")
eq(masks(btn.icon), "picture", "list: the picture wears its own mask")
eq(masks(face), "picture", "...and so does the face already on it")
eq(masks(btn.highlight), "row", "the highlight keeps the row's")
check(btn.backing._shown, "the backing shows on a row")
SlashCmdList.STAKEOUT("layout icons")
eq(masks(btn.icon), "row", "icons: the button's mask again")
eq(masks(face), "row", "...on the face too")
check(not btn.backing._shown and not btn.placeholder._shown, "no backing or placeholder on an icon")

-- Nothing glass builds on the target frame takes the mouse: clicks reach the
-- secure buttons, and the frame's own drag stays the frame's.
for _, w in ipairs(tree(f)) do
    if w ~= f and w._template ~= "SecureActionButtonTemplate" then
        check(not w._mouse, "a glass frame never takes the mouse")
    end
end

-- In combat a new detection builds nothing on the protected frame (the stub
-- throws on any secure write); the button and its glass come after combat.
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
detect("nameplate2", "Other Mob")
eq(#T.buttons, 1, "no button made in combat")
eq(T.pendingRefresh(), true, "the layout waits for combat to end")
-- The plain windows open in combat, glass and all, the first time.
SlashCmdList.STAKEOUT("config")
SlashCmdList.STAKEOUT("export")
check(StakeoutConfigFrame.glass, "the config window opens in glass in combat")
check(StakeoutExportFrame.glass, "the export window too")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
eq(#T.buttons, 2, "the second button is made when combat ends")
check(T.buttons[2].glassPill ~= nil, "with its glass")
-- Sorted by name: the new one takes the first button, the old one moves on.
eq(T.buttons[1]:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Other Mob\n/cleartarget [dead]",
    "the new name's macro")
eq(T.buttons[2]:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Rare Mob\n/cleartarget [dead]",
    "and the first one's")

-- The config window: the large shell, a reading region under the list, the
-- add box a control.
local cg = StakeoutConfigFrame.glass
eq(cg.size, "thin", "the config window: the large shell")
eq(cg.reflect.header._height, 40, "lit down to the rule under its title")
eq(StakeoutConfigFrame._backdrop, nil, "no backdrop under the glass")
eq(StakeoutAddBox.glass and StakeoutAddBox.glass.size, "thin_small", "the add box is a glass control")
eq(color(StakeoutAddBox.glass.tint), rgba(CONTROL.tint), "with the control's tint")
local list = StakeoutScrollFrame._parent
local pane = list.glassReading
check(pane and list._backdrop == nil, "the list sits on a reading region, not a backdrop")
eq(color(pane), rgba(Theme._test.READING), "the reading region's colour")
eq(pane._masks[1]._parent, list, "masked by its own frame")
eq(pane._masks[1]._points[1][2], pane, "to its own rounded shape")

local eg = StakeoutExportFrame.glass
eq(eg.reflect.header._height, 22, "the export window, lit down to its text")
check(StakeoutExportFrame.glassReading, "its text sits on a reading region")
eq(StakeoutExportFrame.glassReading._points[1][2], StakeoutExportScroll, "covering the text's scroll area")
-- The pane shares the export window with its shell: it must draw over every
-- layer of it, or the shell's tint covers the text's backing (Codex on #29).
local over = true
for _, c in ipairs(StakeoutExportFrame._regions) do
    if c ~= StakeoutExportFrame.glassReading and c._layer == "BACKGROUND"
        and (c._sublevel or 0) >= StakeoutExportFrame.glassReading._sublevel then
        over = false
    end
end
check(over, "the export's reading region draws over its window's shell")

-- Last: the sweep clicks Clear All, Reset Detections and every delete.
check(fireAll("glass, out of combat") > 40, "every handler runs under glass")
WoW.combat = true
check(fireAll("glass, in combat") > 40, "and in combat")
WoW.combat = false

------------------------------------------------------------
-- A saved value that isn't a look is the default
------------------------------------------------------------
do
    local T2, Theme2 = session({ svLoadCheck = 1, theme = "chrome" })
    eq(Theme2.Active(), "forever", "an unknown look is WoW Forever")
    check(T2.frame()._backdrop ~= nil, "with its backdrop")
    eq(WoW.chatText():find("glass look", 1, true), nil, "and nothing said")
end

------------------------------------------------------------
-- No library: the WoW Forever look, and the player is told
------------------------------------------------------------
do
    rawset(_G, "LibStub", nil)
    local T3, Theme3 = session({ svLoadCheck = 1, theme = "glass" }, { noLibrary = true })
    eq(Theme3.Active(), "forever", "without LibGlass, WoW Forever")
    check(T3.frame()._backdrop ~= nil, "the frame has its backdrop")
    check(WoW.chatText():find("glass look isn't available (LibGlass-1.0 isn't loaded)", 1, true),
        "the player is told why")
    eq(StakeoutDB.theme, "glass", "and the choice is kept for when the library is back")
    SlashCmdList.STAKEOUT("add Rare Mob")
    detect("nameplate1", "Rare Mob")
    check(T3.buttons[1] and T3.buttons[1].glassPill == nil, "buttons are plain")
end

done("test_theme")
