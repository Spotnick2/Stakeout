-- StakeoutProbe: the in-game check of Stakeout's list layouts (#88), the
-- real ones (Settings, Target frame, Layout). It switches the layout through
-- Stakeout's own /stakeout layout, reads what the rows show, and asks what
-- only the owner can see: whole names, the shadowed placeholder, the target's
-- outline in combat. Reads Stakeout's buttons, never writes to them.
--
-- Procedure: /fp steps so rows.

local _, NS = ...
local Probe = NS.Probe
local function say(msg) Probe:Say(msg) end
local function G(name) return rawget(_G, name) end
local function secret(v)
    local fn = G("issecretvalue")
    return fn ~= nil and fn(v) == true
end
local function plain(v) if type(v) == "string" and not secret(v) then return v end end

local function stakeout(cmd)
    local list = G("SlashCmdList")
    local fn = type(list) == "table" and list.STAKEOUT
    if type(fn) ~= "function" then error("Stakeout isn't loaded", 0) end
    fn(cmd)
end

-- What each shown row shows: one log line per row, and a summary. A throw
-- keeps the step (ForeverProbe's runner), so a read with nothing to read, or
-- a switch combat has deferred, is retried rather than recorded.
local function readRows(layout)
    local lockdown = G("InCombatLockdown")
    if layout and lockdown and lockdown() then
        error("In combat Stakeout keeps the old layout until the fight ends. Press Run again out of combat.", 0)
    end
    -- The layout Stakeout last placed (List and two columns have the same
    -- row height, so the height alone can't tell them apart; Codex on #88).
    local seam = type(G("Stakeout")) == "table" and G("Stakeout")._test
    local applied = type(seam) == "table" and type(seam.appliedLayout) == "function" and seam.appliedLayout()
    if layout and not applied then
        error("This Stakeout can't say which layout it placed: deploy the branch's Stakeout with the probe "
            .. "(Tools/deploy.ps1 -Probe), /reload, then press Run again.", 0)
    end
    if layout and applied ~= layout then
        error(("Stakeout still shows the %s layout, not %s. Press Run again."):format(tostring(applied), layout), 0)
    end
    local rows, pictured, placeheld, ringed = 0, 0, 0, 0
    local texture
    for i = 1, 40 do
        local btn = G("StakeoutBtn" .. i)
        if not btn then break end
        if btn:IsShown() then
            rows = rows + 1
            local name = plain(btn.npcName) or "?"
            local status = btn.progress and plain(btn.progress:GetText()) or ""
            local face = btn.portrait ~= nil and btn.portrait:IsShown()
            local ph = btn.placeholder ~= nil and btn.placeholder:IsShown()
            local ring = btn.ring ~= nil and btn.ring[1]:IsShown()
            if face then pictured = pictured + 1 end
            if ph then
                placeheld = placeheld + 1
                texture = texture or btn.placeholder:GetTexture()
            end
            if ring then ringed = ringed + 1 end
            local w, h = btn:GetSize()
            -- The buttons dressed for the layout asked: rows 22 px tall, icons 26.
            if layout and math.floor((h or 0) + 0.5) ~= (layout == "icons" and 26 or 22) then
                error(("Row %d is %d px tall: the %s layout isn't on the buttons yet. Press Run again.")
                    :format(i, math.floor((h or 0) + 0.5), layout), 0)
            end
            say(("row %d: %s | %s | %dx%d | face %s, placeholder %s, outline %s"):format(i, name, status,
                math.floor((w or 0) + 0.5), math.floor((h or 0) + 0.5), tostring(face), tostring(ph), tostring(ring)))
        end
    end
    if rows == 0 then
        error("Stakeout shows no buttons here. Go near quest mobs (or a watched NPC), then press Run again.", 0)
    end
    local db = G("StakeoutDB")
    layout = layout or (type(db) == "table" and db.layout) or "?"
    return true, ("%s: %d rows, %d faces, %d placeholders (texture %s), %d outlined"):format(tostring(layout),
        rows, pictured, placeheld, tostring(texture), ringed)
end

local function switch(layout)
    return function()
        stakeout("layout " .. layout)
        return readRows(layout)
    end
end

Probe:Steps("rows", {
    rev = 2,
    title = "Stakeout: the list layouts (#88)",
    { text = "Stand where Stakeout shows a few buttons (quest mobs with quest targets on, hunt mode too if you use "
          .. "it), out of combat. Then press Run: the target frame becomes a list.", run = switch("list"),
      screenshot = "rows-list" },
    { text = "Are the names whole, with the quest progress on the right (3/10, turn in, not seen)?", ask = true },
    { text = "A row whose NPC you haven't seen yet: does it show a dark, shadowed silhouette (not an empty square or "
          .. "a green box)? (Not sure if every row has a face already.)", ask = true },
    { text = "Is everything readable against the ground behind it (the backing dark enough)?", ask = true },
    { text = "Press Run for two columns.", run = switch("list2"), screenshot = "rows-list2" },
    { text = "Two rows to a line, each group under its title, nothing overlapping?", ask = true },
    { text = "Target one of the mobs on the list (click its row). Then press Run.", run = function() return readRows() end,
      screenshot = "rows-target" },
    { text = "Does its row have a thin gold outline?", ask = true },
    { text = "Pull it. During the fight, click another mob's row. Does the outline move to that row?", ask = true },
    { text = "When your target dies, does its outline go (combat still on or not)?", ask = true },
    { text = "Out of combat: did a mob you first saw during the fight get its face on the row?", ask = true },
    { text = "Press Run to go back to icons.", run = switch("icons"), screenshot = "rows-icons" },
    { text = "Do the icons look as before (faces kept, labels under the quest buttons, your chosen icon)?",
      ask = true },
    { text = "Anything else? Type it in the box (or nothing), then press Next. Stakeout stays on Icons; set the "
          .. "layout you like in its settings." },
})

-- #98, the Customize panel: its preview beside the live buttons, a few parts
-- turned off, the distance on a button as the owner walks. Opens the panel
-- through Stakeout's own button; the parts are the owner's clicks.
-- Procedure: /fp steps so customize.
local function openCustomize()
    stakeout("config")
    local cfg = G("StakeoutConfigFrame")
    if not (cfg and cfg:IsShown()) then stakeout("config") end
    cfg = G("StakeoutConfigFrame")
    local btn = cfg and cfg.customizeButton
    if not btn then error("This Stakeout has no Customize panel: deploy the branch's Stakeout (Tools/deploy.ps1 -Probe), /reload", 0) end
    local panel = G("StakeoutCustomizeFrame")
    if not (panel and panel:IsShown()) then btn:GetScript("OnClick")(btn) end
    panel = G("StakeoutCustomizeFrame")
    return true, ("panel shown %s, placed %s"):format(tostring(panel and panel:IsShown()), tostring(panel and panel.where))
end

-- Each shown live button's distance text, until it has read two different
-- numbers (the owner walking toward a mob).
local distSeen = {}
local function distanceChanges()
    for i = 1, 40 do
        local btn = G("StakeoutBtn" .. i)
        if not btn then break end
        if btn:IsShown() and btn.dist and btn.dist:IsShown() then
            -- The number only: "30 yd" in a list and "30" on an icon are one
            -- reading (a layout switch isn't a move; Codex on #98's code).
            local t = plain(btn.dist:GetText())
            t = t and t:gsub(" yd$", "")
            if t and t ~= "" then
                local name = plain(btn.npcName) or ("button " .. i)
                distSeen[name] = distSeen[name] or {}
                if not distSeen[name][t] then
                    distSeen[name][t] = true
                    say(("customize: %s shows %s"):format(name, t))
                end
                local n = 0
                for _ in pairs(distSeen[name]) do n = n + 1 end
                if n >= 2 then return true, name .. " changed distance on its button" end
            end
        end
    end
    return false, "walk toward (or away from) a mob that has a button, with Distance ticked"
end
-- Each attempt starts with nothing seen: a later run must see two numbers
-- of its own (Codex on #98's code).
local function forgetDistances() distSeen = {} return true end

-- Where the panel is: visible, on the screen, and anchored as the branch
-- Stakeout chose says (right: its TOPLEFT on the settings' TOPRIGHT; left:
-- TOPRIGHT on TOPLEFT; moved: right of the moved window; over: on the
-- window's TOPLEFT). want: the branch the step expects, or nil for any.
local ANCHORS = { right = { "TOPLEFT", "TOPRIGHT" }, moved = { "TOPLEFT", "TOPRIGHT" },
                  left = { "TOPRIGHT", "TOPLEFT" }, over = { "TOPLEFT", "TOPLEFT" } }
local function where(want)
    return function()
        local panel, cfg = G("StakeoutCustomizeFrame"), G("StakeoutConfigFrame")
        if not (panel and panel:IsVisible()) then error("Open the settings and the Customize panel first (Back)", 0) end
        local sw = G("UIParent") and G("UIParent"):GetWidth()
        if type(want) == "function" then want = want(sw, cfg:GetWidth(), panel:GetWidth()) end
        local point, rel, relPoint, x, y = panel:GetPoint()
        local relName = rel and rel.GetName and rel:GetName() or tostring(rel)
        local l, r = panel:GetLeft(), panel:GetRight()
        local inside = type(l) == "number" and type(r) == "number" and type(sw) == "number" and l >= -0.5
            and r <= sw + 0.5
        local a = ANCHORS[panel.where or ""]
        local anchored = a ~= nil and rel == cfg and point == a[1] and relPoint == a[2]
        local ok = inside and anchored and (want == nil or panel.where == want)
        return ok, ("anchored %s to %s %s (%s, %s); left %s, right %s on a %s px wide screen; placed %s%s"):format(
            tostring(point), tostring(relName), tostring(relPoint), tostring(x), tostring(y),
            tostring(l and math.floor(l)), tostring(r and math.floor(r)), tostring(sw and math.floor(sw)),
            tostring(panel.where), want and (" (wanted " .. want .. ")") or "")
    end
end

-- With the settings at the screen's right edge: on their left when the pair
-- fits the screen, else over their left column (Customize.Place; Codex on
-- #98's code: a 1024-wide screen doesn't hold the 1072 units the pair needs).
local function leftOrOver(sw, cw, pw)
    if type(sw) == "number" and type(cw) == "number" and type(pw) == "number" and sw >= cw + 4 + pw then
        return "left"
    end
    return "over"
end

-- Opens the panel, then switches to a layout (read back from the live frame,
-- as `rows` does) before its screenshot.
local function openAnd(layout)
    return function()
        openCustomize()
        return switch(layout)()
    end
end

Probe:Steps("customize", {
    rev = 2,
    title = "Stakeout: the Customize panel (#98)",
    { text = "Stand where Stakeout shows a few buttons (quest mobs too if you can), out of combat. Press Run: the "
          .. "settings open with the Customize panel beside them, on Icons.", run = openAnd("icons"),
      screenshot = "customize-icons" },
    { text = "Press Run: the list layout, in the preview and on the live buttons.", run = openAnd("list"),
      screenshot = "customize-list" },
    { text = "Press Run: two columns.", run = openAnd("list2"), screenshot = "customize-list2" },
    { text = "Does the preview look like your real buttons (the faces are your own portrait, standing in)?", ask = true },
    { text = "In the panel, untick Portraits, Names and Labels under icons. Then press Next.", screenshot = "customize-parts" },
    { text = "Did the preview and the live buttons both change (no faces, no names)?", ask = true },
    { text = "Tick Distance. Walk toward a mob that has a button until its number changes (up to 3 minutes).",
      when = forgetDistances, wait = distanceChanges, timeout = 180 },
    { text = "Is the number on the button easy to read, and in the right place?", ask = true, screenshot = "customize-distance" },
    { text = "Where the panel went on your screen (logged).", auto = true, run = where(), check = where() },
    { text = "Drag the settings window (by its top) to the right edge of your screen, then press Run: the panel "
          .. "should move to its left (on a narrow screen, over its left column).", run = where(leftOrOver),
      check = where(leftOrOver), screenshot = "customize-left" },
    { text = "Hover a preview button, and a live one: do their tooltips read alike?", ask = true },
    { text = "Anything else? Type it in the box (or nothing). Then tick back what you want, set the layout you "
          .. "like, and press Next." },
})

NS._test = NS._test or {}
NS._test.rows = { readRows = readRows }
NS._test.customize = { openCustomize = openCustomize, distanceChanges = distanceChanges, where = where,
    forgetDistances = forgetDistances, openAnd = openAnd, leftOrOver = leftOrOver }
