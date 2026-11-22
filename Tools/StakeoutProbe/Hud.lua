-- StakeoutProbe: mockups of a list layout for Stakeout's target frame (#88).
-- A picture only: plain frames, never secure, never clicked. It reads what
-- Stakeout's own buttons show now (StakeoutBtn1..N: name, unit, tooltip) and
-- draws them as rows, so the owner can compare layouts on screen with real
-- names, faces and progress.
--
--   /fp so hud compact|wide [forever|glass]   show a mockup (default: compact, forever)
--   /fp so hud demo                           the same with sample rows (nothing on Stakeout's frame)
--   /fp so hud off                            hide it
--   /fp so face                               the target's display ID, and a face drawn from it alone
--
-- Procedures: /fp steps so hud (the layouts), face (a face from a display ID).

local _, NS = ...
local Probe = NS.Probe
local function say(msg) Probe:Say(msg) end
local function G(name) return rawget(_G, name) end
local function secret(v)
    local fn = G("issecretvalue")
    return fn ~= nil and fn(v) == true
end
local function plain(v) if type(v) == "string" and not secret(v) then return v end end

local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local GROUP_TITLES = { "Watch list", "NPCs", "Quest mobs" }

-- Each layout: columns, row height, column width, the font.
local LAYOUTS = {
    compact = { cols = 1, rowH = 22, colW = 190, font = "GameFontHighlightSmall" },
    wide    = { cols = 2, rowH = 34, colW = 220, font = "GameFontHighlight" },
}

-- Sample rows for /fp so hud demo: Stranglethorn's quest mobs, as in the
-- owner's mockup, with two watch names (a full wide line before the next
-- group) and one NPC so the groups show.
local DEMO = {
    { group = 1, name = "King Bangalash" },
    { group = 1, name = "Gorlash" },
    { group = 2, name = "Hemet Nesingwary Jr.", progress = "turn in" },
    { group = 3, name = "Stranglethorn Tiger", progress = "4/10" },
    { group = 3, name = "Stranglethorn Tigress", progress = "2/8", hunt = true },
    { group = 3, name = "Elder Stranglethorn Tiger", progress = "0/8", hunt = true },
    { group = 3, name = "Lashtail Raptor", progress = "6/10" },
    { group = 3, name = "Jungle Stalker", progress = "1/10", hunt = true },
    { group = 3, name = "Shadowmaw Panther", progress = "0/10", hunt = true },
    { group = 3, name = "Bloodscalp Mystic", progress = "3/9" },
    { group = 3, name = "Bloodscalp Beastmaster", progress = "0/9", hunt = true },
}

local hud = { layout = "compact", look = "forever", demo = false, rows = {}, faces = {} }
-- One frame per look, each with its own rows and faces: glass layers can't be
-- taken off a frame, so switching back to Forever must not reuse it (Codex, P2).
local looks = {}

--------------------------------------------------------------------------------
-- What Stakeout shows now
--------------------------------------------------------------------------------

-- "Quest: 3/10 Stranglethorn Tiger slain" -> "3/10"; a turn-in -> "turn in".
local function shortProgress(lines)
    for _, line in ipairs(type(lines) == "table" and lines or {}) do
        local s = plain(line)
        if s then
            local n = s:match("(%d+/%d+)")
            if n then return n end
            if s:find("ready to turn in", 1, true) then return "turn in" end
            if s:find("talk to them", 1, true) then return "talk" end
        end
    end
end

local function isHunt(lines)
    for _, line in ipairs(type(lines) == "table" and lines or {}) do
        local s = plain(line)
        if s and s:find("Not seen yet", 1, true) then return true end
    end
    return false
end

local function stakeoutRows()
    local out = {}
    for i = 1, 40 do
        local btn = G("StakeoutBtn" .. i)
        if not btn then break end
        local name = btn:IsShown() and plain(btn.npcName)
        if name then
            local label = btn.label and plain(btn.label:GetText())
            local group = (label == nil or label == "") and 1 or (btn.friendly and 2 or 3)
            -- Stakeout still shows a face it drew before the mockup opened,
            -- which the mockup can't copy (Codex, P3): btn.portrait since
            -- #90's cache, btn.portraitOf before it. A boolean either way.
            out[#out + 1] = { group = group, name = name, unit = btn.unit, icon = btn.icon and btn.icon:GetTexture(),
                              progress = shortProgress(btn.tooltipLines), hunt = isHunt(btn.tooltipLines),
                              stakeoutFace = btn.portrait ~= nil or btn.portraitOf == name }
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Faces: one per name, drawn when a token shows that NPC, kept after
--------------------------------------------------------------------------------

local function unitName(unit)
    local ok, name = pcall(G("UnitName"), unit)
    return ok and plain(name) or nil
end

local function findUnit(name, hint)
    if hint and unitName(hint) == name then return hint end
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if unitName(unit) == name then return unit end
    end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if unitName(unit) == name then return unit end
    end
end

--------------------------------------------------------------------------------
-- The frame
--------------------------------------------------------------------------------

local glass
local function Glass()
    if glass == nil then
        local stub = G("LibStub")
        local lib = stub and stub("LibGlass-1.0", true)
        local ok, inst = pcall(function() return lib:New({ preset = "clean" }) end)
        glass = ok and inst or false
        if not glass then say("hud: no LibGlass (" .. tostring(inst) .. "), the Forever look instead") end
    end
    return glass or nil
end

local FOREVER_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- A surface in the look: glass from LibGlass, or a tooltip backdrop.
local function dress(f, size, look)
    if look == "glass" and Glass() then
        local ok, err = pcall(glass.Apply, f, size)
        if ok then return end
        say("hud: Glass.Apply failed: " .. tostring(err))
    end
    if f.SetBackdrop then
        f:SetBackdrop(FOREVER_BACKDROP)
        f:SetBackdropColor(0.05, 0.05, 0.08, size == "large" and 0.85 or 0.6)
        f:SetBackdropBorderColor(0.5, 0.5, 0.55, 1)
    end
end

local frame   -- the current look's

local function newRow(name)
    local r = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    r.face = r:CreateTexture(nil, "ARTWORK")
    r.name = r:CreateFontString(nil, "OVERLAY")
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.progress = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.progress:SetJustifyH("RIGHT")
    r.ring = r:CreateTexture(nil, "OVERLAY")       -- the target's outline
    r.ring:SetTexture("Interface\\Buttons\\WHITE8X8")
    r.ring:SetVertexColor(1, 0.82, 0, 0.35)
    r.ring:SetAllPoints()
    r.ring:SetBlendMode("ADD")
    r.ring:Hide()
    r.key = name
    dress(r, "small", hud.look)
    return r
end

-- Places `f` where `old` stands, by screen coordinates against UIParent:
-- never anchored to the other look's frame, which a round trip would make
-- circular (Codex on #91).
local function standWhere(f, old)
    local left, top = old and old:GetLeft(), old and old:GetTop()
    f:ClearAllPoints()
    if type(left) == "number" and type(top) == "number" then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 320, 0)
    end
end

-- The current look's frame, made and dressed once per look, where the
-- previous one stood.
local function build(look)
    look = look or hud.look
    local L = looks[look]
    if L then
        if frame and frame ~= L.frame then
            standWhere(L.frame, frame)
            frame:Hide()
        end
        frame, hud.rows, hud.faces, hud.look = L.frame, L.rows, L.faces, look
        return
    end
    local prev = frame
    frame = CreateFrame("Frame", "StakeoutProbeHud_" .. look, UIParent, "BackdropTemplate")
    standWhere(frame, prev)
    if prev then prev:Hide() end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOP", 0, -8)
    frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.sub:SetPoint("TOP", frame.title, "BOTTOM", 0, -2)
    frame.headers = {}
    frame:Hide()
    dress(frame, "large", look)
    looks[look] = { frame = frame, rows = {}, faces = {} }
    hud.rows, hud.faces, hud.look = looks[look].rows, looks[look].faces, look
end

local function header(i)
    local h = frame.headers[i]
    if not h then
        h = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        h:SetJustifyH("LEFT")
        frame.headers[i] = h
    end
    return h
end

local PAD, GAP = 8, 3

local function render()
    if not (frame and frame:IsShown()) then return end
    local L = LAYOUTS[hud.layout]
    local list = hud.demo and DEMO or stakeoutRows()
    local target = unitName("target")
    frame.title:SetText("Stakeout")
    frame.sub:SetText(("mockup #88: %s, %s%s (not clickable)"):format(hud.layout, hud.look,
        hud.demo and ", sample rows" or ""))

    for _, r in pairs(hud.rows) do r:Hide() end
    for _, h in ipairs(frame.headers) do h:Hide() end

    local y = 40
    local width = L.cols * L.colW + (L.cols - 1) * GAP + 2 * PAD
    -- col: rows placed on the current line (0: none yet). A new group, or a
    -- full line, moves down past the line placed before it (Codex, P2: a
    -- full line at a group's end used to be overlapped).
    local group, col, nHeaders = nil, 0, 0
    for _, e in ipairs(list) do
        if e.group ~= group then
            if col > 0 then y = y + L.rowH + GAP end
            group, col = e.group, 0
            nHeaders = nHeaders + 1
            local h = header(nHeaders)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 2, -y)
            h:SetText(GROUP_TITLES[e.group] or "")
            h:Show()
            y = y + 14
        elseif col == L.cols then
            col = 0
            y = y + L.rowH + GAP
        end
        local r = hud.rows[e.name] or newRow(e.name)
        hud.rows[e.name] = r
        r:SetSize(L.colW, L.rowH)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + col * (L.colW + GAP), -y)

        local s = L.rowH - 4
        r.face:ClearAllPoints()
        r.face:SetPoint("LEFT", r, "LEFT", 2, 0)
        r.face:SetSize(s, s)
        local unit = not hud.demo and findUnit(e.name, e.unit)
        if unit then
            SetPortraitTexture(r.face, unit)
            hud.faces[e.name] = true
            r.face:SetTexCoord(0, 1, 0, 1)
            r.face:SetDesaturated(false)
        elseif not hud.faces[e.name] then
            r.face:SetTexture(e.icon or QUEST_ICON)
            -- Greyed: Stakeout shows a face here that the mockup missed.
            r.face:SetDesaturated(e.stakeoutFace == true)
        end

        r.name:SetFontObject(L.font)
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r.face, "RIGHT", 6, 0)
        r.name:SetPoint("RIGHT", r.progress, "LEFT", -4, 0)
        r.name:SetText(e.name)
        if e.hunt then r.name:SetTextColor(0.65, 0.65, 0.65) else r.name:SetTextColor(1, 1, 1) end

        r.progress:ClearAllPoints()
        r.progress:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.progress:SetText(e.progress or (e.hunt and "not seen" or ""))

        r.ring:SetShown(target ~= nil and target == e.name)
        r:Show()
        col = col + 1
    end
    if col > 0 then y = y + L.rowH end
    frame:SetSize(math.max(width, 200), y + PAD)
    return #list
end

local ticker = CreateFrame("Frame")
ticker.t = 0
ticker:SetScript("OnUpdate", function(self, dt)
    self.t = self.t + dt
    if self.t < 0.5 then return end
    self.t = 0
    render()
end)
ticker:Hide()

local function show(layout, look, demo)
    build(look == "glass" and "glass" or "forever")
    hud.layout = LAYOUTS[layout] and layout or "compact"
    hud.demo = demo and true or false
    frame:Show()
    ticker:Show()
    local n = render()
    say(("hud: %s, %s, %d rows%s"):format(hud.layout, hud.look, n or 0, hud.demo and " (demo)" or ""))
    return hud.layout, hud.look, n
end

local function hide()
    if frame then frame:Hide() end
    ticker:Hide()
    say("hud: off")
    return true
end

--------------------------------------------------------------------------------
-- A face from a display ID alone (#88, question 3)
--------------------------------------------------------------------------------

local model, faceFrame
local face = {}   -- this attempt: name, the ID read, when it started

-- A small frame above the centre: the face from the unit (left) beside the
-- face from the display ID alone (right), to compare.
local function faceBoard()
    if faceFrame then return faceFrame end
    local f = CreateFrame("Frame", "StakeoutProbeFace", UIParent, "BackdropTemplate")
    f:SetSize(220, 92)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    dress(f, "large", "forever")
    f.unitTex = f:CreateTexture(nil, "ARTWORK")
    f.unitTex:SetSize(56, 56)
    f.unitTex:SetPoint("TOPLEFT", 24, -10)
    f.idTex = f:CreateTexture(nil, "ARTWORK")
    f.idTex:SetSize(56, 56)
    f.idTex:SetPoint("TOPRIGHT", -24, -10)
    f.left = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.left:SetPoint("TOP", f.unitTex, "BOTTOM", 0, -4)
    f.left:SetText("from the unit")
    f.right = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.right:SetPoint("TOP", f.idTex, "BOTTOM", 0, -4)
    faceFrame = f
    return f
end

-- Starts reading the target's display ID through a model (no unit API
-- returns it). The model loads over a few frames: pollFace reads it.
local function startFace()
    -- A fresh attempt: nothing from the last one survives (Codex on #91).
    face = {}
    if faceFrame then
        faceFrame.idTex:SetTexture(nil)
        faceFrame.right:SetText("")
    end
    local name = unitName("target")
    if not name then return false, "no target (or its name is secret)" end
    local okDead, dead = pcall(G("UnitIsDead"), "target")
    if okDead and dead == true then return false, "the target is dead: pick a living one" end
    model = model or CreateFrame("PlayerModel", nil, UIParent)
    model:SetSize(64, 64)
    model:SetPoint("TOPLEFT", UIParent, "BOTTOMRIGHT", 10, -10)   -- off screen, still shown
    model:Show()
    model:ClearModel()
    model:SetUnit("target")
    face = { name = name, started = GetTime() }
    local f = faceBoard()
    SetPortraitTexture(f.unitTex, "target")
    f.idTex:SetTexture(nil)
    f.right:SetText("from the display ID: waiting")
    f:Show()
    return true, name
end

-- true, id, how long it took, once the ID is read and the face drawn from it.
-- Anything short of a completed draw keeps waiting (a secret ID, a missing
-- function, a failed call), so a timeout or an early Done stays inconclusive
-- (Codex on #91): face.drawn is what the step's check reads.
local function pollFace()
    if not face.name then return false, "Read face first" end
    local ok, id = pcall(model.GetDisplayInfo, model)
    if not ok then return false, "GetDisplayInfo: " .. tostring(id) end
    if secret(id) then return false, "the display ID is secret" end
    if type(id) ~= "number" or id <= 0 then
        return false, ("display ID %s after %.1f s"):format(tostring(id), GetTime() - face.started)
    end
    local f = faceBoard()
    local fn = G("SetPortraitTextureFromCreatureDisplayID")
    if type(fn) ~= "function" then
        f.right:SetText("the function is missing")
        return false, "SetPortraitTextureFromCreatureDisplayID is missing"
    end
    local drawn, err = pcall(fn, f.idTex, id)
    if not drawn then
        f.right:SetText("drawing failed")
        return false, "SetPortraitTextureFromCreatureDisplayID: " .. tostring(err)
    end
    f.right:SetText(("from display ID %d"):format(id))
    local took = ("%.1f s"):format(GetTime() - face.started)
    say(("face: %s display ID %d after %s, drawn"):format(face.name, id, took))
    face.name, face.drawn = nil, true
    return true, id, took, "drawn"
end

-- The procedure's Read face: a rejected read throws, which keeps the step
-- (ForeverProbe's runner advances on any normal return). The /fp so face
-- command calls startFace itself and just reports the reason.
local function startFaceStep()
    local ok, why = startFace()
    if not ok then error(why, 0) end
    return ok, why
end

local function faceDrawn()
    return face.drawn == true, face.drawn and "drawn" or "no face drawn from the display ID"
end

local function hideFace()
    if faceFrame then faceFrame:Hide() end
    return true
end

-- /fp so face: start, then poll for up to 10 s.
local function readFace()
    local ok, why = startFace()
    if not ok then return nil, why end
    local tries = 0
    local function poll()
        tries = tries + 1
        local done, a, b, c = pollFace()
        if done then return end
        if tries >= 40 then return say("face: gave up, " .. tostring(a)) end
        C_Timer.After(0.25, poll)
    end
    poll()
    return true, why
end

--------------------------------------------------------------------------------
-- Commands and the procedure
--------------------------------------------------------------------------------

Probe:Command("hud", function(arg)
    local a, b = (arg or ""):match("^(%S*)%s*(%S*)")
    if a == "off" then return hide() end
    if a == "demo" then return show(hud.layout, b ~= "" and b or hud.look, true) end
    show(a ~= "" and a or "compact", b ~= "" and b or "forever", false)
end, "compact|wide [forever|glass] | demo | off: the list layout mockup (#88)")

Probe:Command("face", function()
    local ok, why = readFace()
    if not ok then say("face: " .. tostring(why)) end
end, "the target's display ID, and a face drawn from it alone (#88)")

-- Stakeout's rows, or the demo's when its frame shows none (a quiet spot,
-- or Questie still loading): an empty mockup makes an empty screenshot.
local function showForStep(layout, look)
    local l, k, n = show(layout, look, false)
    if (n or 0) > 0 then return l, k, n, "Stakeout's rows" end
    l, k, n = show(layout, look, true)
    return l, k, n, "demo rows: Stakeout showed none"
end

local function step(layout, look)
    return {
        text = ("Showing the %s list, %s look (to the right of the centre; drag it if it's in the way)."):format(
            layout, look == "glass" and "Glass" or "WoW Forever"),
        auto = true, run = function() return showForStep(layout, look) end,
        check = function() return frame and frame:IsShown(), "shown" end,
        screenshot = layout .. "-" .. look,
    }
end

Probe:Steps("hud", {
    rev = 2,
    title = "Stakeout: list layout mockups (#88)",
    { text = "Go where Stakeout shows a few quest buttons (Stranglethorn is ideal), out of combat. Target one of the "
          .. "mobs if you can: its row gets the target's outline. Then press Next." },
    step("compact", "forever"),
    { text = "Compact, WoW Forever: readable at a glance, and a size you'd keep on screen while questing?", ask = true },
    step("wide", "forever"),
    { text = "Wide (two columns), WoW Forever: worth the extra room over compact?", ask = true },
    { text = "Switching to the Glass look.", auto = true, run = function() return showForStep("compact", "glass") end,
      screenshot = "compact-glass" },
    { text = "Compact, Glass: do you prefer it to WoW Forever's compact rows?", ask = true },
    step("wide", "glass"),
    { text = "Wide, Glass: is this the one closest to your mockup?", ask = true },
    { text = "Which would you build: type compact or wide, Forever or Glass, and anything to change, in the Note "
          .. "box. Then press Next." },
    { text = "Hiding the mockup.", auto = true, run = function() return hide() end },
})

Probe:Steps("face", {
    rev = 1,
    title = "Stakeout: a face from a display ID alone (#88, question 3)",
    { text = "Target a living mob or NPC (not a corpse), out of combat, then press Read face. A small frame "
          .. "opens above the centre: its face from the unit on the left.", button = "Read face",
      run = startFaceStep },
    { text = "Reading its display ID (the model takes a moment to load) and drawing a face from that number "
          .. "alone, on the right.", wait = function() return pollFace() end, timeout = 15, check = faceDrawn,
      screenshot = "face-from-display-id" },
    { text = "Does the face on the right show the same creature as the one on the left? (Not sure if the right "
          .. "side is empty.)", ask = true },
    { text = "Once more with a different creature (another kind of mob, or an NPC): target it, then press Read "
          .. "face.", button = "Read face", run = startFaceStep },
    { text = "Reading it.", wait = function() return pollFace() end, timeout = 15, check = faceDrawn,
      screenshot = "face-2" },
    { text = "Does the right one match the left one this time too? (Not sure if the right side is empty.)",
      ask = true },
    { text = "Closing the frame.", auto = true, run = function() return hideFace() end },
})

NS._test = NS._test or {}
NS._test.hud = { show = show, hide = hide, render = render, rows = function() return hud.rows end,
                 frame = function() return frame end, shortProgress = shortProgress, readFace = readFace,
                 startFace = startFace, pollFace = pollFace, startFaceStep = startFaceStep,
                 faceDrawn = faceDrawn, stakeoutRows = stakeoutRows }
