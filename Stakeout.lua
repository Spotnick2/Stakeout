-------------------------------------------------------------------------------
-- Stakeout — watch a list of NPCs and target them with one click
-- WoW: Forever 1.60.1 (Interface 16001). What this client allows is measured
-- in docs/FOREVER-PROBE.md; read AGENTS.md before changing detection or the
-- secure buttons.
-------------------------------------------------------------------------------
local addonName = ...

Stakeout = Stakeout or {}
local Stakeout = Stakeout

-- The client build the rules in AGENTS.md were measured on. A different build
-- gets a one-line note at login until someone re-measures and bumps this.
local MEASURED_ON_BUILD = "69977"

-- Cached API
local fmt              = string.format
local tinsert, tremove = table.insert, table.remove
local GetTime          = GetTime
local InCombatLockdown = InCombatLockdown
local UnitExists       = UnitExists
local UnitName         = UnitName
local UnitGUID         = UnitGUID
local UnitIsDead       = UnitIsDead
local UnitIsPlayer     = UnitIsPlayer
local GetNamePlates    = C_NamePlate.GetNamePlates
local FlashClientIcon  = FlashClientIcon
local PlaySound        = PlaySound
local PlaySoundFile    = PlaySoundFile
local wipe             = wipe
local CreateFrame      = CreateFrame
local issecretvalue    = issecretvalue

-------------------------------------------------------------------------------
-- Settings
--
-- SavedVariables are written but never read back on this client (per
-- character included), so every session starts from these defaults. Every
-- write to StakeoutDB goes through the functions in the owner region below,
-- so Blizzard's fix, or a migration, lands in one place. tests/test_settings
-- fails on a write anywhere else.
-------------------------------------------------------------------------------
local defaults = {
    npcList          = {},      -- { "Mob Name One", "Mob Name Two", ... }
    enableMarking    = true,    -- right-click a button: target and raid-mark
    markerIndex      = 6,       -- blue square (1=star, 2=circle, ... 8=skull)
    buttonIcon       = 1,       -- target frame button icon (see BUTTON_ICONS)
    flashOnFind      = true,    -- flash taskbar icon on detection
    soundOnFind      = true,    -- play sound on first detection
    soundChoice      = "Raid Warning",  -- alert sound name (see GetAlertSounds)
    maxNameplateDist = true,    -- raise the nameplate range
    frameScale       = 1.0,
    lockFrame        = false,
}

-- Whether this session's settings came back from disk. svLoadCheck is written
-- every session and never defaulted, so it is only present at load when the
-- client really read the file - the automatic "is Blizzard's fix in" check.
local settingsLoaded = false

-- config-owner: begin
StakeoutDB = StakeoutDB or {}

local function EnsureDefaults()
    settingsLoaded = StakeoutDB.svLoadCheck ~= nil
    StakeoutDB.svLoadCheck = (tonumber(StakeoutDB.svLoadCheck) or 0) + 1
    for k, v in pairs(defaults) do
        if StakeoutDB[k] == nil then
            -- Tables are copied: the default must not be the live list.
            if type(v) == "table" then
                local copy = {}
                for i, item in ipairs(v) do copy[i] = item end
                v = copy
            end
            StakeoutDB[k] = v
        end
    end
end

local function SetConfig(key, value)
    StakeoutDB[key] = value
end

-- Returns true if the name was added, false if it was already listed.
local function AddNPC(name)
    for _, npc in ipairs(StakeoutDB.npcList) do
        if npc == name then return false end
    end
    tinsert(StakeoutDB.npcList, name)
    return true
end

local function RemoveNPC(name)
    for i, npc in ipairs(StakeoutDB.npcList) do
        if npc == name then
            tremove(StakeoutDB.npcList, i)
            return true
        end
    end
    return false
end

local function ClearNPCs()
    wipe(StakeoutDB.npcList)
end
-- config-owner: end

-------------------------------------------------------------------------------
-- Alert sounds
--
-- Numeric = SoundKit ID or FileDataID. Some entries only play through
-- PlaySoundFile (measured: they are FileDataIDs), so SafePlaySound tries both.
-- Built-in game-file PATHS are refused by this client and are not offered;
-- paths into DBM-Core's folder still play.
-------------------------------------------------------------------------------
local ALERT_SOUNDS_BASE = {
    { name = "Raid Warning",          id = 8959  },
    { name = "Ready Check",           id = 8960  },
    { name = "Whisper",               id = 3081  },
    { name = "Murloc Aggro",          id = 416   },
    { name = "Alarm Clock",           id = 12889 },
    { name = "Loatheb: I See You",    id = 8826  },
    { name = "Horn of Awakening",     id = 7034  },
    { name = "Horn of Cenarius",      id = 10843 },
    { name = "Horn: Dwarf",           id = 10966 },
    { name = "Foghorn",               id = 11630 },
    { name = "Boat Warning",          id = 10170 },
    { name = "PvP Warning: Alliance", id = 8455  },
    { name = "PvP Warning: Horde",    id = 8456  },
    { name = "PvP: Flag Taken",       id = 8457  },
    { name = "PvP: Enter Queue",      id = 8458  },
    { name = "PvP: Through Queue",    id = 8459  },
    { name = "Bell: Dwarf/Gnome",     id = 7234  },
}
-- Requires DBM-Core; string paths always use PlaySoundFile()
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
    if C_AddOns.IsAddOnLoaded("DBM-Core") then
        for _, v in ipairs(ALERT_SOUNDS_DBM_CORE) do tinsert(list, v) end
    end
    return list
end

-- Both PlaySound and PlaySoundFile return `willPlay` first; nil means the
-- engine refused. The caller falls back to Raid Warning.
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
    local choice = StakeoutDB.soundChoice or "Raid Warning"
    local entry
    for _, s in ipairs(GetAlertSounds()) do
        if s.name == choice then entry = s; break end
    end
    entry = entry or ALERT_SOUNDS_BASE[1]
    if not SafePlaySound(entry) and entry ~= ALERT_SOUNDS_BASE[1] then
        SafePlaySound(ALERT_SOUNDS_BASE[1])
    end
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
    local entry = BUTTON_ICONS[StakeoutDB.buttonIcon or 1]
    return entry and entry.texture or BUTTON_ICONS[1].texture
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function Print(msg, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccff[Stakeout]|r " .. fmt(msg, ...))
end

local function IsInNPCList(name)
    for _, npc in ipairs(StakeoutDB.npcList) do
        if npc == name then return true end
    end
    return false
end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- Name and GUID of a live NPC unit, or nil when the unit is absent, dead, a
-- player, or unreadable. Unit identity can be secret on this client, and a
-- secret throws when it is compared or truth-tested, not only when read - so
-- every touch happens inside the pcall. An unreadable unit is never treated
-- as "not on the list"; it simply isn't a sighting.
local function ReadNPC(unit)
    local ok, name, guid = pcall(function()
        if not UnitExists(unit) then return nil end
        local n = UnitName(unit)
        if IsSecret(n) or n == nil then return nil end
        if UnitIsPlayer(unit) or UnitIsDead(unit) then return nil end
        local g = UnitGUID(unit)
        if IsSecret(g) then g = nil end
        return n, g
    end)
    if ok then return name, guid end
    return nil
end

-- RegisterEvent throws on an unknown event and returns false when it refuses
-- one (registering the combat log is refused on this client). Both are
-- reported, so a missing handler is never silent.
local eventFailures = {}
local function RegisterEvents(frame, ...)
    for i = 1, select("#", ...) do
        local event = select(i, ...)
        local ok, registered = pcall(frame.RegisterEvent, frame, event)
        if not ok or registered == false then
            eventFailures[#eventFailures + 1] = event
            Print("|cffff6666Could not listen for %s on this client.|r Please report it.", event)
        end
    end
end

-------------------------------------------------------------------------------
-- Target Frame (the clickable UI)
--
-- The frame parents secure buttons, which makes it protected: in combat it
-- cannot be shown, hidden, moved or re-anchored, and its buttons' attributes
-- cannot change. Everything here defers to PLAYER_REGEN_ENABLED.
-------------------------------------------------------------------------------
local targetFrame
local targetButtons = {}
local detected  = {}   -- [name] = { plates = {[token]=guid|true}, guids = {[guid]=true}, unitId, lastSeen }
local announced = {}   -- [name] = true; one alert per name until it dies or is reset

local function SaveFramePosition(frame)
    local point, _, relPoint, x, y = frame:GetPoint()
    SetConfig("framePos", { point, relPoint, x, y })
end

local function CreateTargetFrame()
    if targetFrame then return end

    targetFrame = CreateFrame("Frame", "StakeoutFrame", UIParent, "BackdropTemplate")

    local f = targetFrame
    f:SetSize(120, 30)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()

    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOP", f, "TOP", 0, -4)
    f.title:SetText("|cff33ccffStakeout|r")

    -- Dragging. Moving a protected frame is refused in combat, so a drag
    -- never starts there, and one that combat interrupts is finished (and
    -- saved) when combat ends.
    f:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or InCombatLockdown() then return end
        if StakeoutDB.lockFrame and not IsAltKeyDown() then return end
        self:StartMoving()
        self.isMoving = true
    end)
    f:SetScript("OnMouseUp", function(self)
        if not self.isMoving then return end
        if InCombatLockdown() then
            self.stopPending = true
            return
        end
        self.isMoving = nil
        self:StopMovingOrSizing()
        SaveFramePosition(self)
    end)

    if StakeoutDB.framePos then
        local p = StakeoutDB.framePos
        f:ClearAllPoints()
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end

    f:SetScale(StakeoutDB.frameScale or 1.0)
end

local function BtnOnEnter(self)
    if self:IsForbidden() or not self.npcName then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(self.npcName, 1, 0.2, 0.2)
    GameTooltip:AddLine("Left-click: target", 0.7, 0.7, 0.7)
    if StakeoutDB.enableMarking then
        GameTooltip:AddLine("Right-click: target and mark", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function BtnOnLeave()
    GameTooltip:Hide()
end

local BUTTONS_PER_ROW = 5
local BUTTON_SIZE     = 26
local BUTTON_PAD      = 2
local HEADER_HEIGHT   = 16

local function RefreshTargetFrame()
    if not targetFrame or InCombatLockdown() then return end

    for _, btn in ipairs(targetButtons) do btn:Hide() end

    local names = {}
    for name in pairs(detected) do tinsert(names, name) end
    table.sort(names)

    if #names == 0 then
        targetFrame:Hide()
        return
    end

    local cols = math.min(#names, BUTTONS_PER_ROW)
    local rows = math.ceil(#names / BUTTONS_PER_ROW)
    local width  = cols * (BUTTON_SIZE + BUTTON_PAD) + BUTTON_PAD + 8
    local height = HEADER_HEIGHT + rows * (BUTTON_SIZE + BUTTON_PAD) + BUTTON_PAD + 4
    targetFrame:SetSize(math.max(width, 90), height)

    for i, name in ipairs(names) do
        local btn = targetButtons[i]
        if not btn then
            btn = CreateFrame("Button", "StakeoutBtn" .. i, targetFrame, "SecureActionButtonTemplate")
            btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
            -- Both edges: the client's secure handler acts on exactly one of
            -- them (ActionButtonUseKeyDown). Never set "typerelease".
            btn:RegisterForClicks("AnyUp", "AnyDown")
            btn:SetAttribute("type", "macro")

            btn.icon = btn:CreateTexture(nil, "BACKGROUND")
            btn.icon:SetAllPoints(true)

            local ht = btn:CreateTexture(nil, "HIGHLIGHT")
            ht:SetAllPoints(true)
            ht:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            ht:SetBlendMode("ADD")

            btn:SetScript("OnEnter", BtnOnEnter)
            btn:SetScript("OnLeave", BtnOnLeave)

            tinsert(targetButtons, btn)
        end

        local col = (i - 1) % BUTTONS_PER_ROW
        local row = math.floor((i - 1) / BUTTONS_PER_ROW)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", targetFrame, "TOPLEFT",
            6 + col * (BUTTON_SIZE + BUTTON_PAD),
            -(HEADER_HEIGHT + 2 + row * (BUTTON_SIZE + BUTTON_PAD)))

        -- The key mechanic: a secure macro targets the NPC by exact name.
        btn:SetAttribute("macrotext", "/cleartarget\n/targetexact " .. name)
        -- SetRaidTarget is forbidden to addon code here, so the mark is the
        -- player's click: right-click targets and marks in one press.
        if StakeoutDB.enableMarking then
            btn:SetAttribute("type2", "macro")
            btn:SetAttribute("macrotext2", fmt("/cleartarget\n/targetexact %s\n/tm %d",
                name, StakeoutDB.markerIndex))
        else
            btn:SetAttribute("type2", nil)
            btn:SetAttribute("macrotext2", nil)
        end
        btn.npcName = name

        local data = detected[name]
        if data.unitId and ReadNPC(data.unitId) == name then
            SetPortraitTexture(btn.icon, data.unitId)
        else
            btn.icon:SetTexture(GetButtonIcon())
        end

        btn:Show()
    end

    targetFrame:Show()
end

-------------------------------------------------------------------------------
-- Detection
--
-- A watched NPC is "detected" while one of its nameplates is up, while the
-- target or mouseover shows it, or for LINGER seconds after it was last seen.
-- Deaths come from UNIT_DIED (the combat log is closed to addons on this
-- client), matched by GUID: an entry holds every GUID seen under its name, so
-- one death never ends the detection of a second NPC with the same name.
--
-- entry.unitId is only the last token it was seen on (for the portrait). It is
-- never evidence of presence: a later sighting overwrites it.
-------------------------------------------------------------------------------
local LINGER = 10

local function Alert(name)
    if announced[name] then return end
    announced[name] = true
    Print("Detected: %s", name)
    if StakeoutDB.flashOnFind then FlashClientIcon() end
    if StakeoutDB.soundOnFind then PlayAlertSound() end
end

local function Sighted(name, guid, unit, isPlate)
    local entry = detected[name]
    if not entry then
        entry = { plates = {}, guids = {} }
        detected[name] = entry
    end
    if guid then entry.guids[guid] = true end
    if isPlate then entry.plates[unit] = guid or true end
    entry.unitId = unit
    entry.lastSeen = GetTime()
    RefreshTargetFrame()
    Alert(name)
end

local function CheckUnit(unit, isPlate)
    local name, guid = ReadNPC(unit)
    if name and IsInNPCList(name) then
        Sighted(name, guid, unit, isPlate)
    end
end

local function ScanAllNameplates()
    for _, plate in ipairs(GetNamePlates() or {}) do
        if plate.namePlateUnitToken then CheckUnit(plate.namePlateUnitToken, true) end
    end
end

-- The target or mouseover shows a live NPC of this name right now.
local function StillVisible(name)
    return ReadNPC("target") == name or ReadNPC("mouseover") == name
end

-- Drop entries with no plate that neither the target nor the mouseover shows
-- and that were last seen more than LINGER seconds ago.
local function Sweep()
    local now, changed = GetTime(), false
    for name, entry in pairs(detected) do
        if not next(entry.plates) then
            if StillVisible(name) then
                entry.lastSeen = now
            elseif now - (entry.lastSeen or 0) > LINGER then
                detected[name] = nil
                changed = true
            end
        end
    end
    if changed then RefreshTargetFrame() end
end

local function PlateRemoved(token)
    for _, entry in pairs(detected) do
        if entry.plates[token] then
            entry.plates[token] = nil
            if entry.unitId == token then entry.unitId = nil end
            -- Out of plate range: gone at once, unless the target or the
            -- mouseover still shows it (Sweep checks).
            if not next(entry.plates) then entry.lastSeen = 0 end
        end
    end
    Sweep()
end

local function UnitDied(guid)
    -- IsSecret first: comparing a secret, even to nil, throws.
    if IsSecret(guid) or guid == nil then return end
    local changed = false
    for name, entry in pairs(detected) do
        if entry.guids[guid] then
            entry.guids[guid] = nil
            for token, g in pairs(entry.plates) do
                if g == guid then entry.plates[token] = nil end
            end
            -- Another NPC of this name was seen and hasn't died: keep the
            -- entry and let Sweep decide whether it is still around.
            if not next(entry.plates) and not next(entry.guids) then
                detected[name] = nil
                announced[name] = nil   -- a respawn alerts again
                changed = true
            end
        end
    end
    if changed then RefreshTargetFrame() end
end

local function ForgetNPC(name)
    detected[name] = nil
    announced[name] = nil
    RefreshTargetFrame()
end

local function ResetDetections()
    wipe(detected)
    wipe(announced)
    RefreshTargetFrame()
    ScanAllNameplates()
end

-- The nameplate range defaults to 45 on this client; only ever raise it.
local NAMEPLATE_DISTANCE = 100
local function ApplyNameplateDistance()
    if not StakeoutDB.maxNameplateDist then return end
    local current = tonumber(C_CVar.GetCVar("nameplateMaxDistance"))
    if current and current < NAMEPLATE_DISTANCE then
        C_CVar.SetCVar("nameplateMaxDistance", tostring(NAMEPLATE_DISTANCE))
    end
end

-------------------------------------------------------------------------------
-- Watch-list import / export
--
-- The watch list does not survive a restart on this client, so it can be
-- exported as `/stakeout add A; B; C` lines (each fits a 255-character macro)
-- and pasted back in one go.
-------------------------------------------------------------------------------
local MACRO_LINE_MAX = 255
local EXPORT_PREFIX  = "/stakeout add "

-- "A; B ;; C" -> { "A", "B", "C" }, trimmed, blanks and repeats dropped.
local function ParseNames(text)
    local names, seen = {}, {}
    for part in ((text or "") .. ";"):gmatch("([^;]*);") do
        local name = part:trim()
        if name ~= "" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

local function ExportLines(list)
    local lines, current = {}, nil
    for _, name in ipairs(list) do
        local candidate = current and (current .. "; " .. name) or (EXPORT_PREFIX .. name)
        if current and #candidate > MACRO_LINE_MAX then
            lines[#lines + 1] = current
            candidate = EXPORT_PREFIX .. name
        end
        current = candidate
    end
    if current then lines[#lines + 1] = current end
    return lines
end

local RefreshNPCList   -- defined with the config GUI

local function AddNames(text)
    local added, already = {}, {}
    for _, name in ipairs(ParseNames(text)) do
        if AddNPC(name) then added[#added + 1] = name else already[#already + 1] = name end
    end
    if #added > 0 then
        Print("|cff00ff00Added:|r %s  (total: %d)", table.concat(added, ", "), #StakeoutDB.npcList)
        ScanAllNameplates()
        RefreshNPCList()
    end
    if #already > 0 then
        Print("|cffff6666Already listed:|r %s", table.concat(already, ", "))
    end
    return #added
end

-- The beta's chat frame cannot be copied from, so exports go into a
-- selectable box: click in it, Ctrl+A, Ctrl+C.
local exportFrame
local function ShowExport()
    local lines = ExportLines(StakeoutDB.npcList)
    if #lines == 0 then
        Print("The watch list is empty - nothing to export.")
        return
    end
    if not exportFrame then
        local f = CreateFrame("Frame", "StakeoutExportFrame", UIParent, "BackdropTemplate")
        exportFrame = f
        f:SetSize(460, 220)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 14, -12)
        title:SetText("Stakeout watch list - Ctrl+A, Ctrl+C, then paste into a macro")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        local scroll = CreateFrame("ScrollFrame", "StakeoutExportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -34)
        scroll:SetPoint("BOTTOMRIGHT", -34, 14)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject("ChatFontNormal")
        eb:SetWidth(400)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() f:Hide() end)
        scroll:SetScrollChild(eb)
        f.eb = eb
        if UISpecialFrames then tinsert(UISpecialFrames, "StakeoutExportFrame") end
    end
    exportFrame.eb:SetText(table.concat(lines, "\n"))
    exportFrame:Show()
    exportFrame.eb:SetFocus()
    exportFrame.eb:HighlightText()
end

-------------------------------------------------------------------------------
-- CONFIG GUI
-------------------------------------------------------------------------------
local configFrame
local MARKER_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
local MARKER_ICONS = {}
for i = 1, 8 do
    MARKER_ICONS[i] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i
end

local npcScrollRows = {}

function RefreshNPCList()
    if not configFrame or not configFrame.scrollContent then return end

    for _, row in ipairs(npcScrollRows) do row:Hide() end

    local parent = configFrame.scrollContent
    local yOff = 0

    for i, npcName in ipairs(StakeoutDB.npcList) do
        local row = npcScrollRows[i]
        if not row then
            row = CreateFrame("Frame", nil, parent)
            row:SetHeight(22)

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints(true)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWidth(260)
            row.label:SetWordWrap(false)

            row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.deleteBtn:SetSize(20, 20)
            row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            row.deleteBtn:SetScript("OnClick", function()
                local name = row.npcName
                if name and RemoveNPC(name) then
                    ForgetNPC(name)
                    RefreshNPCList()
                    Print("|cffff6666Removed:|r %s", name)
                end
            end)

            npcScrollRows[i] = row
        end

        row.npcName = npcName
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

-- Helper: create a labeled checkbox bound to a setting
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
        SetConfig(dbKey, self:GetChecked() and true or false)
        if onChange then onChange(StakeoutDB[dbKey]) end
    end)

    return cb
end

local function MakeBackdrop(frame, edgeSize, insets, bg, border)
    frame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = edgeSize,
        insets = insets,
    })
    frame:SetBackdropColor(unpack(bg))
    frame:SetBackdropBorderColor(unpack(border))
end

local function CreateConfigFrame()
    if configFrame then
        configFrame:SetShown(not configFrame:IsShown())
        if configFrame:IsShown() then RefreshNPCList() end
        return
    end

    local f = CreateFrame("Frame", "StakeoutConfigFrame", UIParent, "BackdropTemplate")
    configFrame = f

    f:SetSize(400, 696)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    MakeBackdrop(f, 16, { left = 4, right = 4, top = 4, bottom = 4 },
        { 0.08, 0.08, 0.10, 0.95 }, { 0.4, 0.4, 0.4, 1 })

    f:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

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

    sectionY = sectionY - 20
    local addBox = CreateFrame("EditBox", "StakeoutAddBox", f, "BackdropTemplate")
    addBox:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    addBox:SetSize(272, 24)
    addBox:SetFontObject("ChatFontNormal")
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(255)
    MakeBackdrop(addBox, 12, { left = 4, right = 4, top = 2, bottom = 2 },
        { 0.1, 0.1, 0.12, 0.9 }, { 0.5, 0.5, 0.5, 0.8 })
    addBox:SetTextInsets(6, 6, 0, 0)

    addBox.placeholder = addBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    addBox.placeholder:SetPoint("LEFT", addBox, "LEFT", 8, 0)
    addBox.placeholder:SetText("Exact NPC name (several: A; B; C)")
    addBox:SetScript("OnEditFocusGained", function(self) self.placeholder:Hide() end)
    addBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then self.placeholder:Show() end
    end)
    addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 4, 0)
    addBtn:SetSize(90, 24)
    addBtn:SetText("Add NPC")

    local function DoAddNPC()
        if AddNames(addBox:GetText()) > 0 then
            addBox:SetText("")
            addBox:ClearFocus()
        end
    end
    addBtn:SetScript("OnClick", DoAddNPC)
    addBox:SetScript("OnEnterPressed", DoAddNPC)

    sectionY = sectionY - 30
    local scrollParent = CreateFrame("Frame", nil, f, "BackdropTemplate")
    scrollParent:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    scrollParent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, sectionY)
    scrollParent:SetHeight(170)
    MakeBackdrop(scrollParent, 12, { left = 2, right = 2, top = 2, bottom = 2 },
        { 0.04, 0.04, 0.06, 0.8 }, { 0.3, 0.3, 0.3, 0.8 })

    local scrollFrame = CreateFrame("ScrollFrame", "StakeoutScrollFrame",
        scrollParent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", -24, 4)

    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetSize(scrollFrame:GetWidth(), 1)
    scrollFrame:SetScrollChild(scrollContent)
    f.scrollContent = scrollContent

    -- Clear all / Reset / Export
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
                ClearNPCs()
                ResetDetections()
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
        ResetDetections()
        Print("Detections reset.")
    end)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
    exportBtn:SetSize(90, 22)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", ShowExport)

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
    MakeCheckbox(f, 10, sectionY - 20, "Raise nameplate range  |cff888888(nameplates find NPCs)|r",
        "maxNameplateDist", function(v)
            if v then ApplyNameplateDistance() end
        end)

    ---------------------------------------------------------------------------
    -- Section: Alerts
    ---------------------------------------------------------------------------
    sectionY = sectionY - 52

    local alertHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alertHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 14, sectionY)
    alertHeader:SetText("Alerts")

    sectionY = sectionY - 4
    MakeCheckbox(f, 10, sectionY - 20, "Flash taskbar on detection", "flashOnFind")
    MakeCheckbox(f, 10, sectionY - 44, "Play sound on detection", "soundOnFind")

    sectionY = sectionY - 68
    local soundLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    soundLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, sectionY)
    soundLabel:SetText("Sound:")

    local soundDropdown = CreateFrame("Frame", "StakeoutSoundDropdown", f, "UIDropDownMenuTemplate")
    soundDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 46, sectionY + 7)
    UIDropDownMenu_SetWidth(soundDropdown, 190)

    UIDropDownMenu_Initialize(soundDropdown, function()
        local current = StakeoutDB.soundChoice or "Raid Warning"
        for _, entry in ipairs(GetAlertSounds()) do
            local entryName = entry.name
            local info      = UIDropDownMenu_CreateInfo()
            info.text    = entryName
            info.value   = entryName
            info.checked = (current == entryName)
            info.func = function()
                UIDropDownMenu_SetText(soundDropdown, entryName)
                SetConfig("soundChoice", entryName)
                -- Preview with the runtime logic, so the answer is honest.
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
    MakeCheckbox(f, 10, sectionY - 20, "Right-click a button to target and mark",
        "enableMarking", function() RefreshTargetFrame() end)

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
            SetConfig("markerIndex", idx)
            for _, b in ipairs(markerButtons) do b.selected:Hide() end
            mb.selected:Show()
            RefreshTargetFrame()
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
            SetConfig("buttonIcon", idx)
            for _, b in ipairs(iconButtons) do b.selected:Hide() end
            ib.selected:Show()
            RefreshTargetFrame()
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

    slider:SetScript("OnValueChanged", function(_, val)
        val = math.floor(val / 10 + 0.5) * 10
        SetConfig("frameScale", val / 100)
        -- The target frame is protected; rescale it once combat ends.
        if targetFrame and not InCombatLockdown() then targetFrame:SetScale(StakeoutDB.frameScale) end
        UpdateScaleLabel(val)
    end)

    -- ESC closes config
    if UISpecialFrames then tinsert(UISpecialFrames, "StakeoutConfigFrame") end

    RefreshNPCList()
    f:Show()
end

-------------------------------------------------------------------------------
-- Event frame
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local sweepTicker

local function OnLogin()
    local build = select(2, GetBuildInfo())
    Print("Loaded. |cff00ff00/stakeout|r to open config. Tracking %d NPCs.", #StakeoutDB.npcList)
    if not settingsLoaded then
        Print("|cffffcc00This beta client doesn't reload saved settings (a Blizzard bug), so the watch " ..
            "list starts empty.|r Keep a copy with |cff00ff00/stakeout export|r and paste it back in one go.")
    end
    if build ~= MEASURED_ON_BUILD then
        Print("Tested on client build %s; this is %s. Report anything that behaves oddly.",
            MEASURED_ON_BUILD, tostring(build))
    end
end

local function OnCombatEnd()
    if targetFrame then
        if targetFrame.stopPending then
            targetFrame.stopPending = nil
            targetFrame.isMoving = nil
            targetFrame:StopMovingOrSizing()
            SaveFramePosition(targetFrame)
        end
        targetFrame:SetScale(StakeoutDB.frameScale or 1.0)
    end
    RefreshTargetFrame()
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")

        EnsureDefaults()
        CreateTargetFrame()
        ApplyNameplateDistance()

        RegisterEvents(self, "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "NAME_PLATE_UNIT_ADDED",
            "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_DIED")
        sweepTicker = C_Timer.NewTicker(1, Sweep)

        ScanAllNameplates()

    elseif event == "PLAYER_LOGIN" then
        OnLogin()

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        CheckUnit(..., true)

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        PlateRemoved(...)

    elseif event == "PLAYER_TARGET_CHANGED" then
        CheckUnit("target", false)

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CheckUnit("mouseover", false)

    elseif event == "UNIT_DIED" then
        UnitDied(...)

    elseif event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnd()
    end
end)
RegisterEvents(eventFrame, "ADDON_LOADED")

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
        AddNames(rest)

    elseif cmd == "remove" or cmd == "del" then
        if rest == "" then Print("Usage: /stakeout remove <Exact NPC Name>") return end
        if RemoveNPC(rest) then
            ForgetNPC(rest)
            RefreshNPCList()
            Print("|cffff6666Removed:|r %s", rest)
        else
            Print("'%s' not found in list.", rest)
        end

    elseif cmd == "list" then
        if #StakeoutDB.npcList == 0 then
            Print("NPC list is empty. Use |cff00ff00/stakeout add <name>|r or open config.")
        else
            Print("Tracked NPCs (%d):", #StakeoutDB.npcList)
            for i, npc in ipairs(StakeoutDB.npcList) do
                Print("  %d. %s", i, npc)
            end
        end

    elseif cmd == "export" then
        ShowExport()

    elseif cmd == "clear" then
        ClearNPCs()
        ResetDetections()
        RefreshNPCList()
        Print("NPC list cleared.")

    elseif cmd == "reset" then
        ResetDetections()
        Print("Detections reset. Rescanning...")

    else
        Print("|cff33ccff--- Stakeout ---|r")
        Print("  /stakeout                     — Open config panel")
        Print("  /stakeout add <Name>; <Name>  — Add one or more NPCs")
        Print("  /stakeout remove <Name>       — Remove an NPC")
        Print("  /stakeout list                — List tracked NPCs in chat")
        Print("  /stakeout export              — Copy the list as /stakeout add lines")
        Print("  /stakeout clear               — Remove all NPCs")
        Print("  /stakeout reset               — Clear detections & rescan")
    end
end

-------------------------------------------------------------------------------
-- Test seam (tests/). Harmless in game.
-------------------------------------------------------------------------------
Stakeout._test = {
    detected = detected, announced = announced, eventFailures = eventFailures,
    ReadNPC = ReadNPC, CheckUnit = CheckUnit, PlateRemoved = PlateRemoved,
    UnitDied = UnitDied, Sweep = Sweep, ParseNames = ParseNames, ExportLines = ExportLines,
    AddNames = AddNames, RefreshTargetFrame = RefreshTargetFrame, OnCombatEnd = OnCombatEnd,
    CreateConfigFrame = CreateConfigFrame, ShowExport = ShowExport,
    ApplyNameplateDistance = ApplyNameplateDistance, RegisterEvents = RegisterEvents,
    buttons = targetButtons, frame = function() return targetFrame end,
    settingsLoaded = function() return settingsLoaded end,
    LINGER = LINGER, MEASURED_ON_BUILD = MEASURED_ON_BUILD,
}
