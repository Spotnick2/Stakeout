-------------------------------------------------------------------------------
-- Stakeout — Standalone NPC detector with clickable target frame
-- Replicates the RXPGuides targeting mechanic for any user-defined NPC list
-------------------------------------------------------------------------------
local addonName = ...

-- Saved variables (persisted between sessions)
StakeoutDB = StakeoutDB or NPCScannerDB or {}

-------------------------------------------------------------------------------
-- Defaults & state
-------------------------------------------------------------------------------
local defaults = {
    npcList         = {},       -- { "Mob Name One", "Mob Name Two", ... }
    enableMarking   = true,     -- auto raid-mark detected NPCs
    markerIndex     = 6,        -- default blue square (1=star,2=circle,...8=skull)
    buttonIcon      = 1,        -- target frame button icon index (see BUTTON_ICONS)
    enableProximity = true,     -- use TargetUnit() proximity trick
    pollInterval    = 0.25,     -- proximity poll rate in seconds
    flashOnFind     = true,     -- flash taskbar icon on detection
    soundOnFind     = true,     -- play sound on first detection
    soundChoice     = "Raid Warning",  -- alert sound name (see GetAlertSounds)
    maxNameplateDist= true,     -- push nameplate range to max
    frameScale      = 1.0,
    lockFrame       = false,
}

local function EnsureDefaults()
    for k, v in pairs(defaults) do
        if StakeoutDB[k] == nil then StakeoutDB[k] = v end
    end
    -- v1.1 migration: default marker changed from skull(8) to blue square(6)
    if not StakeoutDB._v then
        if StakeoutDB.markerIndex == 8 then
            StakeoutDB.markerIndex = 6
        end
        StakeoutDB._v = 1
    end
end

-- Runtime tables
local detectedUnits   = {}  -- [name] = { kind, lastSeen }
local announcedUnits  = {}  -- [name] = true  (prevents spam)
local proxScanData    = nil -- current proximity scan context
local proxMatch       = false
local proxLastMatch   = 0
local PROX_TIMEOUT    = 5

-- Frame references
local targetFrame
local targetButtons   = {}
local configFrame     -- config GUI

-- Alert sound choices
-- numeric = SoundKit ID → PlaySound(); string = game file path → PlaySoundFile()
-- IMPORTANT (TBC Classic 2.5.x): PlaySound() ONLY accepts real SoundKit IDs from
-- SoundKitEntry.db2. Many IDs shown on Wowhead are actually FileDataIDs. Our
-- SafePlaySound helper tries PlaySound first, then PlaySoundFile for the same
-- number (which accepts FileDataIDs on modern Classic clients), then falls back
-- to Raid Warning — so numeric entries that look broken get two chances before
-- the failsafe kicks in. File-path strings go straight to PlaySoundFile.
local ALERT_SOUNDS_BASE = {
    -- Standard UI — verified SoundKit IDs
    { name = "Raid Warning",          id = SOUNDKIT.RAID_WARNING      or 8959 },
    { name = "Ready Check",           id = SOUNDKIT.READY_CHECK       or 8960 },
    { name = "Whisper",               id = SOUNDKIT.TELL_MESSAGE      or 3081 },
    { name = "Murloc Aggro",          id = SOUNDKIT.MURLOC_AGGRO      or 416  },
    { name = "Alarm Clock",           id = SOUNDKIT.ALARM_CLOCK_WARNING_3 or 12889 },
    { name = "Loatheb: I See You",    id = 8826  },

    -- Horns (original numeric IDs; safe-play has FileDataID fallback)
    { name = "Horn of Awakening",     id = 7034  },
    { name = "Horn of Cenarius",      id = 10843 },
    { name = "Horn: Dwarf",           id = 10966 },

    -- Nautical
    { name = "Foghorn",               id = 11630 },
    { name = "Boat Warning",          id = 10170 },

    -- PvP cluster (8458/8459 verified in SOUNDKIT; 8455-8457 are adjacent IDs
    -- in the same cluster, strong evidence they're real SoundKit entries too)
    { name = "PvP Warning: Alliance", id = 8455 },
    { name = "PvP Warning: Horde",    id = 8456 },
    { name = "PvP: Flag Taken",       id = 8457 },
    { name = "PvP: Enter Queue",      id = SOUNDKIT.PVP_ENTER_QUEUE   or 8458 },
    { name = "PvP: Through Queue",    id = SOUNDKIT.PVP_THROUGH_QUEUE or 8459 },

    -- Bells (confirmed SOUNDKIT ID; file-path variants below use .ogg extension)
    { name = "Bell: Dwarf/Gnome",     id = 7234  },
    { name = "Bell: Alliance",        id = "Sound\\Doodad\\BellTollAlliance.ogg"  },
    { name = "Bell: Horde",           id = "Sound\\Doodad\\BellTollHorde.ogg"     },
    { name = "Bell: Night Elf",       id = "Sound\\Doodad\\BellTollNightElf.ogg"  },
    { name = "Bell: Karazhan",        id = "Sound\\Doodad\\KharazahnBellToll.ogg" },

    -- Atmospheric / event (file paths — LFG Broker verified)
    { name = "Ogre War Drums",        id = "Sound\\Event Sounds\\Event_wardrum_ogre.ogg" },
    { name = "Troll Drums",           id = "Sound\\Doodad\\TrollDrumLoop1.ogg"           },
    { name = "Fireworks",             id = "Sound\\Doodad\\G_FireworkLauncher02Custom0.ogg" },
    { name = "Goblin Spring",         id = "Sound\\Doodad\\Goblin_Lottery_Open03.ogg"    },
    { name = "Gnome Yell",            id = "Sound\\Character\\Gnome\\GnomeVocalFemale\\GnomeFemalePissed01.ogg" },
}
-- Requires DBM-Core to be installed; string paths always use PlaySoundFile()
local ALERT_SOUNDS_DBM_CORE = {
    { name = "Algalon: Beware!",        id = "Interface\\AddOns\\DBM-Core\\sounds\\ClassicSupport\\UR_Algalon_BHole01.ogg" },
    { name = "BB Wolf: Run Away",       id = "Interface\\AddOns\\DBM-Core\\sounds\\ClassicSupport\\HoodWolfTransformPlayer01.ogg" },
    { name = "Illidan: Not Prepared",   id = "Interface\\AddOns\\DBM-Core\\sounds\\ClassicSupport\\BLACK_Illidan_04.ogg" },
    { name = "Illidan: Not Prepared2",  id = "Interface\\AddOns\\DBM-Core\\sounds\\ClassicSupport\\VO_703_Illidan_Stormrage_03.ogg" },
    { name = "Kil'Jaeden: Destruction", id = "Interface\\AddOns\\DBM-Core\\sounds\\ClassicSupport\\KILJAEDEN02.ogg" },
    { name = "Air Horn",                id = "Interface\\AddOns\\DBM-Core\\sounds\\AirHorn.ogg" },
    { name = "Alarm Clock (DBM)",       id = "Interface\\AddOns\\DBM-Core\\sounds\\alarmclockbeeps.ogg" },
}

local function GetAlertSounds()
    local list = {}
    for _, v in ipairs(ALERT_SOUNDS_BASE) do tinsert(list, v) end
    -- C_AddOns.IsAddOnLoaded is a modern API; fall back to the legacy global on
    -- older Classic builds so DBM-Core sounds still show up everywhere.
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if isLoaded and isLoaded("DBM-Core") then
        for _, v in ipairs(ALERT_SOUNDS_DBM_CORE) do tinsert(list, v) end
    end
    return list
end

-- Button icon choices for the target frame
local BUTTON_ICONS = {
    { name = "Sword",         texture = 135274 },                                              -- INV_Sword_04
    { name = "Blue Square",   texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6" },
    { name = "Skull",         texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { name = "Star",          texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1" },
    { name = "Moon",          texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5" },
    { name = "Crosshair",     texture = "Interface\\Minimap\\Tracking\\None" },
    { name = "Exclamation",   texture = "Interface\\GossipFrame\\AvailableQuestIcon" },
    { name = "Eye",           texture = "Interface\\Icons\\Ability_EyeOfTheOwl" },
}

local function GetButtonIcon()
    local idx = StakeoutDB.buttonIcon or 1
    local entry = BUTTON_ICONS[idx]
    return entry and entry.texture or BUTTON_ICONS[1].texture
end

-- Cached API
local fmt             = string.format
local tinsert, tremove = table.insert, table.remove
local GetTime         = GetTime
local InCombatLockdown = InCombatLockdown
local UnitName        = UnitName
local UnitIsDead      = UnitIsDead
local UnitIsPlayer    = UnitIsPlayer
local TargetUnit      = TargetUnit
local GetRaidTargetIndex = GetRaidTargetIndex
local SetRaidTarget   = SetRaidTarget
local GetNamePlates   = C_NamePlate.GetNamePlates
local FlashClientIcon = FlashClientIcon
local PlaySound       = PlaySound
local PlaySoundFile   = PlaySoundFile
local wipe            = wipe
local CreateFrame     = CreateFrame

-- Play a sound entry. Both PlaySound and PlaySoundFile return `willPlay` as
-- their first value — nil means the engine refused (bad SoundKit ID, missing
-- file, muted channel). For numeric IDs we try PlaySound (SoundKit) first; if
-- that fails we try PlaySoundFile (which on modern Classic clients also
-- accepts FileDataIDs) so IDs that turned out to be FileDataIDs still play.
-- If both paths fail, the caller falls back to Raid Warning.
local function SafePlaySound(entry)
    if not entry then return false end
    local id = entry.id
    if type(id) == "string" then
        return PlaySoundFile(id, "Master") and true or false
    elseif type(id) == "number" then
        if PlaySound(id, "Master") then return true end
        return PlaySoundFile(id, "Master") and true or false
    end
    return false
end

local function PlayAlertSound()
    local choice = StakeoutDB and StakeoutDB.soundChoice or "Raid Warning"
    if type(choice) == "number" then choice = "Raid Warning" end  -- legacy migration
    local sounds = GetAlertSounds()
    local entry
    for _, s in ipairs(sounds) do
        if s.name == choice then entry = s; break end
    end
    entry = entry or ALERT_SOUNDS_BASE[1]
    if not SafePlaySound(entry) then
        -- Chosen sound didn't play (missing file / invalid SoundKit on this
        -- client). Fall back to Raid Warning, which is guaranteed to exist.
        if entry ~= ALERT_SOUNDS_BASE[1] then
            SafePlaySound(ALERT_SOUNDS_BASE[1])
        end
    end
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function IsInNPCList(name)
    if not name then return false end
    for _, npc in ipairs(StakeoutDB.npcList) do
        if npc == name then return true end
    end
    return false
end

local function Print(msg, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccff[Stakeout]|r " .. fmt(msg, ...))
end

-------------------------------------------------------------------------------
-- Target Frame (the clickable UI)
-------------------------------------------------------------------------------
local function CreateTargetFrame()
    if targetFrame then return end

    targetFrame = CreateFrame("Frame", "StakeoutFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)

    local f = targetFrame
    f:SetSize(120, 30)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()

    -- Backdrop
    local backdrop = {
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    }
    f:SetBackdrop(backdrop)
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)

    -- Title bar
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOP", f, "TOP", 0, -4)
    f.title:SetText("|cff33ccffStakeout|r")

    -- Dragging
    f:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and (not StakeoutDB.lockFrame or IsAltKeyDown()) then
            self:StartMoving()
        end
    end)
    f:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        StakeoutDB.framePos = { point, relPoint, x, y }
    end)

    -- Restore saved position
    if StakeoutDB.framePos then
        local p = StakeoutDB.framePos
        f:ClearAllPoints()
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end

    f:SetScale(StakeoutDB.frameScale or 1.0)
end

-------------------------------------------------------------------------------
-- Tooltip helpers for buttons
-------------------------------------------------------------------------------
local function BtnOnEnter(self)
    if self:IsForbidden() or not self.npcName then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(self.npcName, 1, 0.2, 0.2)
    GameTooltip:AddLine("Click to target", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function BtnOnLeave(self)
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- Refresh the target frame buttons
-------------------------------------------------------------------------------
local BUTTONS_PER_ROW = 5
local BUTTON_SIZE     = 26
local BUTTON_PAD      = 2
local HEADER_HEIGHT   = 16

local function RefreshTargetFrame()
    if not targetFrame or InCombatLockdown() then return end

    -- Hide all existing buttons
    for _, btn in ipairs(targetButtons) do btn:Hide() end

    -- Collect active names
    local names = {}
    for name, _ in pairs(detectedUnits) do
        tinsert(names, name)
    end
    table.sort(names)

    if #names == 0 then
        targetFrame:Hide()
        return
    end

    -- Size the frame
    local cols = math.min(#names, BUTTONS_PER_ROW)
    local rows = math.ceil(#names / BUTTONS_PER_ROW)
    local width  = cols * (BUTTON_SIZE + BUTTON_PAD) + BUTTON_PAD + 8
    local height = HEADER_HEIGHT + rows * (BUTTON_SIZE + BUTTON_PAD) + BUTTON_PAD + 4

    targetFrame:SetSize(math.max(width, 90), height)

    for i, name in ipairs(names) do
        local btn = targetButtons[i]
        if not btn then
            btn = CreateFrame("Button", "StakeoutBtn" .. i, targetFrame,
                "SecureActionButtonTemplate")
            btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
            btn:SetAttribute("type", "macro")

            if btn.RegisterForClicks then
                btn:RegisterForClicks("AnyUp", "AnyDown")
            end

            -- Icon texture — configurable placeholder
            btn.icon = btn:CreateTexture(nil, "BACKGROUND")
            btn.icon:SetAllPoints(true)
            btn.icon:SetTexture(GetButtonIcon())

            -- Highlight
            local ht = btn:CreateTexture(nil, "HIGHLIGHT")
            ht:SetAllPoints(true)
            ht:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            ht:SetBlendMode("ADD")

            btn:SetScript("OnEnter", BtnOnEnter)
            btn:SetScript("OnLeave", BtnOnLeave)

            tinsert(targetButtons, btn)
        end

        -- Position in grid
        local col = (i - 1) % BUTTONS_PER_ROW
        local row = math.floor((i - 1) / BUTTONS_PER_ROW)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", targetFrame, "TOPLEFT",
            6 + col * (BUTTON_SIZE + BUTTON_PAD),
            -(HEADER_HEIGHT + 2 + row * (BUTTON_SIZE + BUTTON_PAD)))

        -- The key mechanic: secure macro targets the NPC by exact name
        btn:SetAttribute("macrotext", "/cleartarget\n/targetexact " .. name)
        btn.npcName = name

        -- Try to show portrait if we have a nameplate unit for it
        local data = detectedUnits[name]
        if data and data.unitId and UnitName(data.unitId) == name then
            SetPortraitTexture(btn.icon, data.unitId)
        else
            btn.icon:SetTexture(GetButtonIcon())
        end

        btn:Show()
    end

    targetFrame:Show()
end

-------------------------------------------------------------------------------
-- Raid marking
-------------------------------------------------------------------------------
local function TryMarkUnit(unitId)
    if not StakeoutDB.enableMarking then return end
    if not unitId then return end
    if UnitIsDead(unitId) or UnitIsPlayer(unitId) then return end
    if GetRaidTargetIndex(unitId) then return end

    SetRaidTarget(unitId, StakeoutDB.markerIndex)
end

-------------------------------------------------------------------------------
-- Core: Nameplate scanning
-------------------------------------------------------------------------------
local function CheckNameplate(unitId)
    if not unitId then return end
    local name = UnitName(unitId)
    if not name or not IsInNPCList(name) then return end
    if UnitIsDead(unitId) then return end

    local isNew = not detectedUnits[name]
    detectedUnits[name] = { kind = "nameplate", unitId = unitId, lastSeen = GetTime() }

    TryMarkUnit(unitId)
    RefreshTargetFrame()

    if isNew and not announcedUnits[name] then
        announcedUnits[name] = true
        Print("Detected: %s", name)
        if StakeoutDB.flashOnFind then FlashClientIcon() end
        if StakeoutDB.soundOnFind then PlayAlertSound() end
    end
end

local function ScanAllNameplates()
    local plates = GetNamePlates()
    if not plates then return end
    for _, plate in ipairs(plates) do
        CheckNameplate(plate.namePlateUnitToken)
    end
end

-------------------------------------------------------------------------------
-- Core: Proximity polling (TargetUnit trick)
-------------------------------------------------------------------------------
local proxTicker

local function ProximityPoll()
    if InCombatLockdown() then return end
    if not StakeoutDB.enableProximity then return end
    if not StakeoutDB.npcList or #StakeoutDB.npcList == 0 then return end

    for _, name in ipairs(StakeoutDB.npcList) do
        proxScanData = name
        TargetUnit(name, true)
    end
    proxScanData = nil

    -- Expire stale detections
    local now = GetTime()
    if proxMatch and now - proxLastMatch > PROX_TIMEOUT then
        proxMatch = false
        wipe(announcedUnits)
    end

    local changed = false
    for name, data in pairs(detectedUnits) do
        if data.kind == "proximity" and now - data.lastSeen > PROX_TIMEOUT then
            detectedUnits[name] = nil
            changed = true
        end
    end
    if changed and not InCombatLockdown() then RefreshTargetFrame() end
end

-------------------------------------------------------------------------------
-- Suppress the "addon action forbidden" popup
-------------------------------------------------------------------------------
local forbiddenText = fmt(ADDON_ACTION_FORBIDDEN, addonName)

local function SuppressForbiddenPopup(self)
    local textWidget = self.text or self.Text
    if textWidget and textWidget:GetText() == forbiddenText then
        if self:IsShown() then self:Hide() end
        local _, channel = PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE)
        if channel then
            StopSound(channel)
            StopSound(channel - 1)
        end
        StaticPopupDialogs["ADDON_ACTION_FORBIDDEN"] = nil
    end
end

-------------------------------------------------------------------------------
-- CONFIG GUI
-------------------------------------------------------------------------------
local MARKER_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
local MARKER_ICONS = {}
for i = 1, 8 do
    MARKER_ICONS[i] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i
end

local npcScrollRows = {}

local function RefreshNPCList()
    if not configFrame or not configFrame.scrollContent then return end

    for _, row in ipairs(npcScrollRows) do row:Hide() end

    local parent = configFrame.scrollContent
    local yOff = 0

    for i, npcName in ipairs(StakeoutDB.npcList) do
        local row = npcScrollRows[i]
        if not row then
            row = CreateFrame("Frame", nil, parent,
                BackdropTemplateMixin and "BackdropTemplate" or nil)
            row:SetHeight(22)

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints(true)
            row.bg:SetColorTexture(1, 1, 1, 0.03)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWidth(260)
            row.label:SetWordWrap(false)

            row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.deleteBtn:SetSize(20, 20)
            row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            row.deleteBtn:SetScript("OnClick", function()
                local idx = row.npcIndex
                if idx and StakeoutDB.npcList[idx] then
                    local removed = StakeoutDB.npcList[idx]
                    tremove(StakeoutDB.npcList, idx)
                    detectedUnits[removed] = nil
                    announcedUnits[removed] = nil
                    if not InCombatLockdown() then RefreshTargetFrame() end
                    RefreshNPCList()
                    Print("|cffff6666Removed:|r %s", removed)
                end
            end)

            npcScrollRows[i] = row
        end

        row.npcIndex = i
        row.label:SetText(fmt("%d.  %s", i, npcName))
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0.0)

        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOff)
        row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
        row:Show()
        yOff = yOff + 22
    end

    parent:SetHeight(math.max(yOff, 1))

    if configFrame.countLabel then
        configFrame.countLabel:SetText(fmt("Tracked: |cffffffff%d|r", #StakeoutDB.npcList))
    end
end

-- Helper: create a labeled checkbox
local function MakeCheckbox(parent, x, y, label, dbKey, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local text = cb.text or cb.Text
    if text then
        text:SetText(label)
        text:SetFontObject("GameFontNormalSmall")
    end

    cb:SetChecked(StakeoutDB[dbKey])
    cb:SetScript("OnClick", function(self)
        StakeoutDB[dbKey] = self:GetChecked() and true or false
        if onChange then onChange(StakeoutDB[dbKey]) end
    end)

    return cb
end

local function CreateConfigFrame()
    if configFrame then
        configFrame:SetShown(not configFrame:IsShown())
        if configFrame:IsShown() then RefreshNPCList() end
        return
    end

    local f = CreateFrame("Frame", "StakeoutConfigFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    configFrame = f

    f:SetSize(400, 720)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)

    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    f:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("|cff33ccffStakeout|r")

    ---------------------------------------------------------------------------
    -- Section: NPC List
    ---------------------------------------------------------------------------
    local sectionY = -38

    local npcHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    npcHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    npcHeader:SetText("Watch List")

    f.countLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.countLabel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, sectionY - 1)

    -- Add NPC input row
    sectionY = sectionY - 20
    local addBox = CreateFrame("EditBox", "StakeoutAddBox", f,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    addBox:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    addBox:SetSize(272, 24)
    addBox:SetFontObject("ChatFontNormal")
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(100)
    addBox:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 2, bottom = 2 },
    })
    addBox:SetBackdropColor(0.1, 0.1, 0.12, 0.9)
    addBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    addBox:SetTextInsets(6, 6, 0, 0)

    addBox.placeholder = addBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    addBox.placeholder:SetPoint("LEFT", addBox, "LEFT", 8, 0)
    addBox.placeholder:SetText("Enter exact NPC name...")
    addBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
    end)
    addBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then self.placeholder:Show() end
    end)
    addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 4, 0)
    addBtn:SetSize(90, 24)
    addBtn:SetText("Add NPC")

    local function DoAddNPC()
        local name = addBox:GetText():trim()
        if name == "" then return end
        for _, npc in ipairs(StakeoutDB.npcList) do
            if npc == name then
                Print("|cffff6666%s|r is already in the list.", name)
                return
            end
        end
        tinsert(StakeoutDB.npcList, name)
        Print("|cff00ff00Added:|r %s", name)
        addBox:SetText("")
        addBox:ClearFocus()
        RefreshNPCList()
        ScanAllNameplates()
    end

    addBtn:SetScript("OnClick", DoAddNPC)
    addBox:SetScript("OnEnterPressed", function() DoAddNPC() end)

    -- Scroll frame for the NPC list
    sectionY = sectionY - 30
    local scrollParent = CreateFrame("Frame", nil, f,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    scrollParent:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    scrollParent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, sectionY)
    scrollParent:SetHeight(170)
    scrollParent:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    scrollParent:SetBackdropColor(0.04, 0.04, 0.06, 0.8)
    scrollParent:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    local scrollFrame = CreateFrame("ScrollFrame", "StakeoutScrollFrame",
        scrollParent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", -24, 4)

    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetSize(scrollFrame:GetWidth(), 1)
    scrollFrame:SetScrollChild(scrollContent)
    f.scrollContent = scrollContent

    -- Clear all / Reset buttons
    sectionY = sectionY - 178
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    clearBtn:SetSize(100, 22)
    clearBtn:SetText("Clear All")
    clearBtn:SetScript("OnClick", function()
        StaticPopupDialogs["STAKEOUT_CLEAR_CONFIRM"] = {
            text = "Remove all NPCs from the watch list?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                wipe(StakeoutDB.npcList)
                wipe(detectedUnits)
                wipe(announcedUnits)
                if not InCombatLockdown() then RefreshTargetFrame() end
                RefreshNPCList()
                Print("NPC list cleared.")
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("STAKEOUT_CLEAR_CONFIRM")
    end)

    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetPoint("LEFT", clearBtn, "RIGHT", 6, 0)
    resetBtn:SetSize(130, 22)
    resetBtn:SetText("Reset Detections")
    resetBtn:SetScript("OnClick", function()
        wipe(detectedUnits)
        wipe(announcedUnits)
        ScanAllNameplates()
        Print("Detections reset.")
    end)

    ---------------------------------------------------------------------------
    -- Divider
    ---------------------------------------------------------------------------
    sectionY = sectionY - 30
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, sectionY)
    divider:SetHeight(1)
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    ---------------------------------------------------------------------------
    -- Section: Detection
    ---------------------------------------------------------------------------
    sectionY = sectionY - 14

    local optHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    optHeader:SetText("Detection")

    sectionY = sectionY - 4
    MakeCheckbox(f, 10, sectionY - 20, "Proximity scanning  |cff888888(TargetUnit trick)|r",
        "enableProximity", function(v)
        Print("Proximity scanning: %s |cff888888(reload UI to fully apply)|r",
            v and "|cff00ff00ON|r" or "|cffff6666OFF|r")
    end)

    MakeCheckbox(f, 10, sectionY - 44, "Max nameplate distance", "maxNameplateDist", function(v)
        if v then
            local version = select(4, GetBuildInfo()) or 0
            SetCVar("nameplateMaxDistance", version > 40000 and "100" or "41")
        end
    end)

    ---------------------------------------------------------------------------
    -- Section: Alerts
    ---------------------------------------------------------------------------
    sectionY = sectionY - 76

    local alertHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alertHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    alertHeader:SetText("Alerts")

    sectionY = sectionY - 4
    MakeCheckbox(f, 10, sectionY - 20, "Flash taskbar on detection", "flashOnFind")
    MakeCheckbox(f, 10, sectionY - 44, "Play sound on detection", "soundOnFind")

    -- Sound selector dropdown
    sectionY = sectionY - 68
    local soundLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    soundLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, sectionY)
    soundLabel:SetText("Sound:")

    local soundDropdown = CreateFrame("Frame", "StakeoutSoundDropdown", f, "UIDropDownMenuTemplate")
    soundDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 46, sectionY + 7)
    UIDropDownMenu_SetWidth(soundDropdown, 190)

    UIDropDownMenu_Initialize(soundDropdown, function()
        local sounds  = GetAlertSounds()
        local current = StakeoutDB.soundChoice or "Raid Warning"
        for _, entry in ipairs(sounds) do
            local entryName = entry.name
            local info      = UIDropDownMenu_CreateInfo()
            info.text    = entryName
            info.value   = entryName
            info.checked = (current == entryName)
            info.func = function()
                UIDropDownMenu_SetText(soundDropdown, entryName)
                StakeoutDB.soundChoice = entryName
                -- Preview with the same safe-play logic used at runtime so the
                -- user gets an honest answer about whether the sound works.
                if not SafePlaySound(entry) then
                    Print("|cffff6666Couldn't play '%s' on this client.|r Falling back to Raid Warning.", entryName)
                    SafePlaySound(ALERT_SOUNDS_BASE[1])
                else
                    Print("Alert sound set to: %s", entryName)
                end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(soundDropdown, StakeoutDB.soundChoice or "Raid Warning")

    ---------------------------------------------------------------------------
    -- Section: Raid Marking
    ---------------------------------------------------------------------------
    sectionY = sectionY - 32

    local markHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    markHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    markHeader:SetText("Raid Marking")

    sectionY = sectionY - 4
    MakeCheckbox(f, 10, sectionY - 20, "Auto mark detected NPCs", "enableMarking")

    -- Marker icon selector row
    sectionY = sectionY - 46
    local markerLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    markerLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, sectionY)
    markerLabel:SetText("Marker:")

    local markerButtons = {}
    for idx = 1, 8 do
        local mb = CreateFrame("Button", nil, f)
        mb:SetSize(22, 22)
        mb:SetPoint("LEFT", markerLabel, "RIGHT", 4 + (idx - 1) * 26, 0)

        mb.icon = mb:CreateTexture(nil, "ARTWORK")
        mb.icon:SetAllPoints(true)
        mb.icon:SetTexture(MARKER_ICONS[idx])

        mb.selected = mb:CreateTexture(nil, "OVERLAY")
        mb.selected:SetPoint("TOPLEFT", -2, 2)
        mb.selected:SetPoint("BOTTOMRIGHT", 2, -2)
        mb.selected:SetColorTexture(1, 1, 1, 0.25)
        mb.selected:Hide()

        mb.ht = mb:CreateTexture(nil, "HIGHLIGHT")
        mb.ht:SetAllPoints(true)
        mb.ht:SetColorTexture(1, 1, 1, 0.15)

        mb:SetScript("OnClick", function()
            StakeoutDB.markerIndex = idx
            for _, b in ipairs(markerButtons) do b.selected:Hide() end
            mb.selected:Show()
            Print("Marker set to: %s", MARKER_NAMES[idx])
        end)

        mb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(MARKER_NAMES[idx], 1, 1, 1)
            GameTooltip:Show()
        end)
        mb:SetScript("OnLeave", function() GameTooltip:Hide() end)

        if StakeoutDB.markerIndex == idx then mb.selected:Show() end
        markerButtons[idx] = mb
    end

    ---------------------------------------------------------------------------
    -- Section: Target Frame
    ---------------------------------------------------------------------------
    sectionY = sectionY - 34

    local frameHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frameHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    frameHeader:SetText("Target Frame")

    sectionY = sectionY - 4
    MakeCheckbox(f, 10, sectionY - 20, "Lock frame position  |cff888888(Alt+drag overrides)|r", "lockFrame")

    -- Button icon selector
    sectionY = sectionY - 46
    local iconLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    iconLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, sectionY)
    iconLabel:SetText("Button icon:")

    local iconButtons = {}
    for idx, entry in ipairs(BUTTON_ICONS) do
        local ib = CreateFrame("Button", nil, f)
        ib:SetSize(22, 22)
        ib:SetPoint("LEFT", iconLabel, "RIGHT", 4 + (idx - 1) * 26, 0)

        ib.icon = ib:CreateTexture(nil, "ARTWORK")
        ib.icon:SetAllPoints(true)
        ib.icon:SetTexture(entry.texture)

        ib.selected = ib:CreateTexture(nil, "OVERLAY")
        ib.selected:SetPoint("TOPLEFT", -2, 2)
        ib.selected:SetPoint("BOTTOMRIGHT", 2, -2)
        ib.selected:SetColorTexture(1, 1, 1, 0.25)
        ib.selected:Hide()

        ib.ht = ib:CreateTexture(nil, "HIGHLIGHT")
        ib.ht:SetAllPoints(true)
        ib.ht:SetColorTexture(1, 1, 1, 0.15)

        ib:SetScript("OnClick", function()
            StakeoutDB.buttonIcon = idx
            for _, b in ipairs(iconButtons) do b.selected:Hide() end
            ib.selected:Show()
            -- Refresh existing buttons to show new icon
            if not InCombatLockdown() then RefreshTargetFrame() end
            Print("Button icon set to: %s", entry.name)
        end)

        ib:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(entry.name, 1, 1, 1)
            GameTooltip:Show()
        end)
        ib:SetScript("OnLeave", function() GameTooltip:Hide() end)

        if (StakeoutDB.buttonIcon or 1) == idx then ib.selected:Show() end
        iconButtons[idx] = ib
    end

    -- Scale slider
    sectionY = sectionY - 30
    local scaleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scaleLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, sectionY)

    local slider = CreateFrame("Slider", "StakeoutScaleSlider", f, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", f, "TOPLEFT", 16, sectionY - 18)
    slider:SetWidth(220)
    slider:SetMinMaxValues(50, 300)
    slider:SetValueStep(10)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue((StakeoutDB.frameScale or 1.0) * 100)

    slider.Low  = slider.Low  or _G[slider:GetName() .. "Low"]
    slider.High = slider.High or _G[slider:GetName() .. "High"]
    slider.Text = slider.Text or _G[slider:GetName() .. "Text"]
    if slider.Low  then slider.Low:SetText("0.5x")  end
    if slider.High then slider.High:SetText("3.0x") end
    if slider.Text then slider.Text:SetText("")      end

    local function UpdateScaleLabel(val)
        scaleLabel:SetText(fmt("Scale: |cffffffff%.0f%%|r", val))
    end
    UpdateScaleLabel(slider:GetValue())

    slider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val / 10 + 0.5) * 10
        StakeoutDB.frameScale = val / 100
        if targetFrame then targetFrame:SetScale(StakeoutDB.frameScale) end
        UpdateScaleLabel(val)
    end)

    -- ESC closes config
    tinsert(UISpecialFrames, "StakeoutConfigFrame")

    RefreshNPCList()
    f:Show()
end

-------------------------------------------------------------------------------
-- Event frame
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")

        EnsureDefaults()
        CreateTargetFrame()

        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

        if StakeoutDB.maxNameplateDist then
            local version = select(4, GetBuildInfo()) or 0
            if version > 40000 then
                SetCVar("nameplateMaxDistance", "100")
            else
                SetCVar("nameplateMaxDistance", "41")
            end
        end

        if StakeoutDB.enableProximity then
            proxTicker = C_Timer.NewTicker(StakeoutDB.pollInterval, ProximityPoll)
            self:RegisterEvent("ADDON_ACTION_FORBIDDEN")
            UIParent:UnregisterEvent("ADDON_ACTION_FORBIDDEN")

            if StaticPopup1 then
                StaticPopup1:HookScript("OnShow", SuppressForbiddenPopup)
                StaticPopup1:HookScript("OnHide", SuppressForbiddenPopup)
            end
            if StaticPopup2 then
                StaticPopup2:HookScript("OnShow", SuppressForbiddenPopup)
                StaticPopup2:HookScript("OnHide", SuppressForbiddenPopup)
            end
        end

        ScanAllNameplates()
        Print("Loaded. |cff00ff00/stakeout|r to open config. Tracking %d NPCs.", #StakeoutDB.npcList)

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        CheckNameplate(...)

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local unitId = ...
        if not unitId then return end
        local name = UnitName(unitId)
        if name and detectedUnits[name] then
            local data = detectedUnits[name]
            if data.unitId == unitId then
                data.unitId = nil
                if not StakeoutDB.enableProximity then
                    detectedUnits[name] = nil
                    if not InCombatLockdown() then RefreshTargetFrame() end
                end
            end
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        local name = UnitName("target")
        if name and detectedUnits[name] then
            detectedUnits[name].unitId = "target"
            TryMarkUnit("target")
            if not InCombatLockdown() then RefreshTargetFrame() end
        end

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        local name = UnitName("mouseover")
        if name and IsInNPCList(name) and not UnitIsDead("mouseover") then
            local isNew = not detectedUnits[name]
            detectedUnits[name] = { kind = "mouseover", unitId = "mouseover", lastSeen = GetTime() }
            TryMarkUnit("mouseover")
            if not InCombatLockdown() then RefreshTargetFrame() end
            if isNew and not announcedUnits[name] then
                announcedUnits[name] = true
                Print("Detected: %s", name)
                if StakeoutDB.flashOnFind then FlashClientIcon() end
                if StakeoutDB.soundOnFind then PlayAlertSound() end
            end
        end

    elseif event == "ADDON_ACTION_FORBIDDEN" then
        local forbiddenAddon, func = ...
        if func ~= "TargetUnit()" or forbiddenAddon ~= addonName then return end
        if not proxScanData then return end

        local name = proxScanData
        local now  = GetTime()
        local isNew = not detectedUnits[name]
        detectedUnits[name] = { kind = "proximity", lastSeen = now }
        proxLastMatch = now
        proxMatch = true

        if not InCombatLockdown() then RefreshTargetFrame() end

        if isNew and not announcedUnits[name] then
            announcedUnits[name] = true
            Print("Nearby: %s (proximity)", name)
            if StakeoutDB.flashOnFind then FlashClientIcon() end
            if StakeoutDB.soundOnFind then PlayAlertSound() end
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        RefreshTargetFrame()

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subEvent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
        if subEvent == "UNIT_DIED" and destName and detectedUnits[destName] then
            detectedUnits[destName] = nil
            announcedUnits[destName] = nil
            if not InCombatLockdown() then RefreshTargetFrame() end
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_STAKEOUT1 = "/stakeout"
SLASH_STAKEOUT2 = "/stake"

SlashCmdList["STAKEOUT"] = function(input)
    input = (input or ""):trim()
    local cmd, rest = input:match("^(%S+)%s*(.*)")
    cmd  = cmd  and cmd:lower() or ""
    rest = rest and rest:trim() or ""

    if cmd == "config" or cmd == "options" or cmd == "settings" or cmd == "" then
        CreateConfigFrame()

    elseif cmd == "add" and rest ~= "" then
        for _, npc in ipairs(StakeoutDB.npcList) do
            if npc == rest then
                Print("|cffff6666%s|r is already in the list.", rest)
                return
            end
        end
        tinsert(StakeoutDB.npcList, rest)
        Print("|cff00ff00Added:|r %s  (total: %d)", rest, #StakeoutDB.npcList)
        ScanAllNameplates()
        RefreshNPCList()

    elseif cmd == "remove" or cmd == "del" then
        if rest == "" then Print("Usage: /stakeout remove <Exact NPC Name>") return end
        for i, npc in ipairs(StakeoutDB.npcList) do
            if npc == rest then
                tremove(StakeoutDB.npcList, i)
                detectedUnits[rest] = nil
                announcedUnits[rest] = nil
                if not InCombatLockdown() then RefreshTargetFrame() end
                RefreshNPCList()
                Print("|cffff6666Removed:|r %s", rest)
                return
            end
        end
        Print("'%s' not found in list.", rest)

    elseif cmd == "list" then
        if #StakeoutDB.npcList == 0 then
            Print("NPC list is empty. Use |cff00ff00/stakeout add <n>|r or open config.")
        else
            Print("Tracked NPCs (%d):", #StakeoutDB.npcList)
            for i, npc in ipairs(StakeoutDB.npcList) do
                Print("  %d. %s", i, npc)
            end
        end

    elseif cmd == "clear" then
        wipe(StakeoutDB.npcList)
        wipe(detectedUnits)
        wipe(announcedUnits)
        Print("NPC list cleared.")
        if not InCombatLockdown() then RefreshTargetFrame() end
        RefreshNPCList()

    elseif cmd == "reset" then
        wipe(detectedUnits)
        wipe(announcedUnits)
        Print("Detections reset. Rescanning...")
        ScanAllNameplates()

    else
        Print("|cff33ccff--- Stakeout ---|r")
        Print("  /stakeout                — Open config panel")
        Print("  /stakeout add <NPC Name> — Quick-add an NPC")
        Print("  /stakeout remove <NPC Name> — Quick-remove an NPC")
        Print("  /stakeout list          — List tracked NPCs in chat")
        Print("  /stakeout clear         — Remove all NPCs")
        Print("  /stakeout reset         — Clear detections & rescan")
    end
end