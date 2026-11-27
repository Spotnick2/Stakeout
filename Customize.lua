-------------------------------------------------------------------------------
-- Stakeout: the Customize panel (#98)
--
-- A panel beside the settings window: a preview of the target buttons, the
-- Layout, Button icon and Scale rows, and what the buttons and their tooltips
-- show. The preview draws plain buttons through the same functions as the
-- target frame's secure ones (ns.looks, in Stakeout.lua), from fixed samples:
-- never the player's own targets. Nothing here touches the target frame,
-- which takes a change at its next render, out of combat.
--
-- Designed with Codex over 13 rounds (#95 and #98's plan).
-------------------------------------------------------------------------------
local _, ns = ...

local Customize = {}
ns.customize = Customize

local L = ns.looks
local Theme = ns.theme

local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local BOX_H = 150          -- the preview's box, the samples scaled to fit it
local GAP = 4              -- between the settings window and the panel

-- The samples: one of each kind, fixed. A face is the player's own portrait,
-- standing in for an NPC's (a preview can't draw one it hasn't seen).
local CLICKS = { "Left-click: target and mark", "Right-click: target only" }
local SAMPLES = {
    { group = 1, name = "Mor'Ladim", face = true, clicks = CLICKS },
    { group = 2, name = "Cook Torka", friendly = true, quest = true, icon = QUEST_ICON,
      progress = "turn in", progressMax = "turn in", tooltip = { "Lazy Peons: ready to turn in" }, clicks = CLICKS },
    { group = 3, name = "Bloodscalp Warrior", quest = true, icon = QUEST_ICON, face = true,
      progress = "3/10", progressMax = "10/10", alertOn = true, targeted = true, low = 25, high = 30,
      tooltip = { "Bloodscalp Ears: 3/10 Bloodscalp Warrior slain" }, clicks = CLICKS },
    { group = 3, name = "Kobold Laborer", quest = true, icon = QUEST_ICON, hunt = true,
      tooltip = { "Not seen yet" }, clicks = { "Click to look for one", CLICKS[1], CLICKS[2] } },
}
Customize.SAMPLES = SAMPLES

local panel, cfg, stage, scaleNote
local buttons = {}

-- The sample's tooltip, by the live tooltip's rules.
local function SampleOnEnter(self)
    local e = self.sample
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    local R = ns.range
    L.FillTooltip(GameTooltip, { name = e.name, friendly = e.friendly, distance = R and R.TextOf(e.low, e.high),
        lines = e.tooltip, clicks = e.clicks, quest = e.quest, alertOn = e.alertOn, hunt = e.hunt })
    GameTooltip:Show()
end
local function SampleOnLeave() GameTooltip:Hide() end

local function SampleButton(i)
    local b = buttons[i]
    if b then return b end
    -- A plain Button: never secure, it targets nothing and rebuilds in combat.
    b = CreateFrame("Button", nil, stage)
    L.BuildRegions(b)
    b:SetScript("OnEnter", SampleOnEnter)
    b:SetScript("OnLeave", SampleOnLeave)
    buttons[i] = b
    return b
end

-- The preview: the saved settings (a change shows at once, also in combat),
-- the current layout, the scale up to what fits the box.
function Customize.Redraw()
    if not stage then return end
    local f = L.Flags()
    local layout = StakeoutDB.layout
    if not L.LAYOUT_LABELS[layout] then layout = "icons" end
    local rows = layout ~= "icons"
    local g = {}
    if rows then g.width, g.status, g.dist = L.RowGeometry(SAMPLES, f) end
    for i in ipairs(SAMPLES) do SampleButton(i):Show() end
    for i = #SAMPLES + 1, #buttons do buttons[i]:Hide() end
    L.PlaceButtons(SAMPLES, layout, g, f, stage, buttons)
    local questNames = {}
    for _, e in ipairs(SAMPLES) do if e.group > 1 then questNames[#questNames + 1] = e.name end end
    local R = ns.range
    for i, e in ipairs(SAMPLES) do
        local b = buttons[i]
        b.sample = e
        L.LookButton(b, e, questNames)
        if e.face and f.portraits then
            SetPortraitTexture(b.icon, "player")
            b.icon:Show()
            b.placeholder:Hide()
        else
            L.NoFace(b, e, rows, f.portraits)
        end
        b.bell:SetShown(e.alertOn == true)
        for _, t in ipairs(b.ring) do t:SetShown(e.targeted == true) end
        local short = R and R.ShortOf(e.low, e.high)
        b.dist:SetText(short and (rows and (short .. " yd") or short) or "")
    end
    -- The player's scale, unless the box can't hold it.
    local want = StakeoutDB.frameScale or 1.0
    local w, h = stage:GetWidth(), stage:GetHeight()
    local bw, bh = Customize.box:GetWidth(), Customize.box:GetHeight()
    local scale = want
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
        scale = math.min(want, bw / w, bh / h)
    end
    stage:SetScale(scale)
    if scale < want - 0.001 then
        scaleNote:SetText(("(shown at %d%%)"):format(math.floor(scale * 100 + 0.5)))
    else
        scaleNote:SetText("")
    end
end

-- Beside the settings window, where the screen has room (Codex on the plan):
-- on its right, else its left, else the window moves so both fit, else over
-- its left column (the watch list, back when the panel closes).
function Customize.Place()
    if not (panel and panel:IsShown() and cfg) then return end
    local sw = UIParent:GetWidth() or 0
    local left, right, top = cfg:GetLeft(), cfg:GetRight(), cfg:GetTop()
    local pw, cw = panel:GetWidth(), cfg:GetWidth()
    panel:ClearAllPoints()
    panel.where = nil
    if type(left) ~= "number" or type(right) ~= "number" or sw <= 0 then
        panel:SetPoint("TOPLEFT", cfg, "TOPRIGHT", GAP, 0)
        panel.where = "right"
    elseif right + GAP + pw <= sw then
        panel:SetPoint("TOPLEFT", cfg, "TOPRIGHT", GAP, 0)
        panel.where = "right"
    elseif left - GAP - pw >= 0 then
        panel:SetPoint("TOPRIGHT", cfg, "TOPLEFT", -GAP, 0)
        panel.where = "left"
    elseif cw + GAP + pw <= sw then
        -- The window moves over so the pair fits, its top where it was.
        local newLeft = math.floor((sw - (cw + GAP + pw)) / 2)
        cfg:ClearAllPoints()
        if type(top) == "number" then
            cfg:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", newLeft, top)
        else
            cfg:SetPoint("LEFT", UIParent, "LEFT", newLeft, 0)
        end
        panel:SetPoint("TOPLEFT", cfg, "TOPRIGHT", GAP, 0)
        panel.where = "moved"
    else
        panel:SetPoint("TOPLEFT", cfg, "TOPLEFT", 0, 0)
        panel:SetFrameLevel((cfg:GetFrameLevel() or 1) + 20)
        panel.where = "over"
    end
end

function Customize.Toggle()
    if not panel then return end
    panel:SetShown(not panel:IsShown())
    if panel:IsShown() then
        Customize.Redraw()
        Customize.Place()
    end
end

-- A part's checkbox: saved, the preview redrawn, the target frame told (it
-- applies the change at its next render, out of combat).
local function PartBox(H, x, y, label, key)
    return H.MakeCheckbox(panel, x, y, label, key, function()
        Customize.Redraw()
        H.RefreshTargetFrame()
    end)
end

function Customize.Build(config, H)
    if panel then return panel end
    cfg = config
    local W = H.COL_W + 32
    panel = CreateFrame("Frame", "StakeoutCustomizeFrame", config, "BackdropTemplate")
    Customize.panel = panel
    panel:SetWidth(W)
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:Hide()
    H.StyleWindow(panel, { header = 40 })

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", panel, "TOP", 0, -12)
    title:SetText("Buttons")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    H.Rule(panel, 14, -40, W - 28)

    local x, y = 16, -50
    -- The preview: the target frame's own look, on a box it's scaled to fit.
    local box = CreateFrame("Frame", nil, panel)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    box:SetSize(W - 32, BOX_H)
    Customize.box = box
    stage = CreateFrame("Frame", nil, box, "BackdropTemplate")
    Customize.stage = stage
    stage:SetPoint("TOP", box, "TOP", 0, 0)
    stage:SetSize(120, 30)
    if not (Theme and Theme.Window(stage, { small = true, header = L.HEADER_HEIGHT })) then
        stage:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        stage:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
        stage:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)
    end
    stage.title = stage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stage.title:SetPoint("TOP", stage, "TOP", 0, -4)
    stage.title:SetText("|cff33ccffStakeout|r")
    scaleNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    scaleNote:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -2)
    Customize.scaleNote = scaleNote

    -- Layout, Button icon, Scale (moved here from the settings' right column).
    y = y - BOX_H - 18
    y = L.BuildFrameControls(panel, config, x, y, Customize.Redraw)

    -- What the buttons and their tooltips show: two columns.
    y = y - 4
    H.Rule(panel, x, y, W - 32)
    y = y - 12
    local half = math.floor((W - 32) / 2)
    H.SectionTitle(panel, x, y, "On the buttons")
    H.SectionTitle(panel, x + half, y, "In the tooltip")
    y = y - 26
    local boxes = {}
    local parts = {
        { "Portraits", "showPortraits" }, { "Names", "showNames" }, { "Progress", "showProgress" },
        { "Labels under icons", "showLabels" }, { "Distance", "showDistance" },
    }
    for i, p in ipairs(parts) do boxes[p[2]] = PartBox(H, x, y - (i - 1) * 30, p[1], p[2]) end
    local tips = { { "Distance", "tipDistance" }, { "Quest progress", "tipProgress" }, { "Click hints", "tipClicks" } }
    for i, p in ipairs(tips) do boxes[p[2]] = PartBox(H, x + half, y - (i - 1) * 30, p[1], p[2]) end
    Customize.boxes = boxes
    y = y - #parts * 30 - 10
    panel:SetHeight(math.max(-y, config:GetHeight() or 0))

    -- The panel follows the screen too.
    panel:RegisterEvent("DISPLAY_SIZE_CHANGED")
    panel:RegisterEvent("UI_SCALE_CHANGED")
    panel:SetScript("OnEvent", function() Customize.Place() end)
    panel:SetScript("OnHide", function(self)
        if self.where == "over" then self:SetFrameLevel(cfg:GetFrameLevel() or 1) end
    end)

    L.OnLooksChanged = Customize.Redraw
    Customize.Redraw()
    return panel
end

Customize._test = { buttons = buttons, SAMPLES = SAMPLES }
