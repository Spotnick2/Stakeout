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

NS._test = NS._test or {}
NS._test.rows = { readRows = readRows }
