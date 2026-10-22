-------------------------------------------------------------------------------
-- Stakeout — watch a list of NPCs and target them with one click
-- WoW: Forever 1.60.1 (Interface 16001). What this client allows is measured
-- in docs/FOREVER-PROBE.md; read AGENTS.md before changing detection or the
-- secure buttons.
-------------------------------------------------------------------------------
local addonName, ns = ...
ns = ns or {}
-- Theme.lua loads first: the windows' look (WoW Forever, or glass).
local Theme = ns.theme

Stakeout = Stakeout or {}
local Stakeout = Stakeout

-- The client build the rules in AGENTS.md were measured on. A development copy
-- says once, at the first login on each new client build, that the build moved
-- on from the last one it saw (from this, when it has seen none). A release
-- keeps quiet (IsDevelopmentCopy).
local MEASURED_ON_BUILD = "70450"

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
    frameScale       = 1.0,
    lockFrame        = false,
    theme            = "forever",  -- the windows' look, "forever" or "glass" (Theme.lua; after a /reload)
    followGlassUI    = true,    -- with Glass UI loaded, wear its look (Theme.lua; after a /reload)
    questTargets     = false,   -- experimental: buttons for what the quest log wants (Quests.lua)
    questOther       = false,   -- ...and for other units the client relates to a quest
    questMutes       = {},      -- [muteKey] = true; see SetQuestMute
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
    -- The "raise the nameplate range" option is gone: plates stop at about
    -- 40 yd on this client whatever it was set to (FOREVER-PROBE.md §7).
    StakeoutDB.maxNameplateDist = nil
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

-- Quest target mutes (Quests.lua). "q<questID>" mutes a whole quest, and
-- "q<questID>:<objKey>:<npcId|name>" one target of one of its objectives.
-- Returns false for a key of neither shape.
local function SetQuestMute(key, on)
    if type(key) ~= "string" or not key:find("^q%d+$") and not key:find("^q%d+:.+:.+$") then return false end
    if type(StakeoutDB.questMutes) ~= "table" then StakeoutDB.questMutes = {} end
    StakeoutDB.questMutes[key] = on and true or nil
    return true
end

-- Forget the mutes of quests that left the log; activeIDs is [questID] = true.
-- Quests.lua calls this only after a read of an initialized log, so a log that
-- isn't loaded yet never wipes them. Returns how many went.
local function PruneQuestMutes(activeIDs)
    local mutes = StakeoutDB.questMutes
    if type(mutes) ~= "table" or type(activeIDs) ~= "table" then return 0 end
    local dropped = 0
    for key in pairs(mutes) do
        local id = type(key) == "string" and tonumber(key:match("^q(%d+)")) or nil
        if not (id and activeIDs[id]) then
            mutes[key] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end
-- config-owner: end

-- The saved look; anything unknown is the default.
local function StoredLook()
    return Theme.IsLook(StakeoutDB.theme) and StakeoutDB.theme or "forever"
end

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

-- Longer than any NPC name, and short enough that one name always fits a
-- macro line, the "#stakeout" marker line included.
local NAME_MAX = 100

-- A name that can go into a /targetexact line as it is: a plain string, no
-- control character (a newline would start a second macro command), and no
-- longer than NAME_MAX. Names that come from other addons' data pass this
-- before they reach a button.
local function MacroSafeName(name)
    return type(name) == "string" and not IsSecret(name) and name ~= ""
        and #name <= NAME_MAX and not name:find("%c")
end

-- Name and GUID of a live NPC unit, or nil when the unit is absent, dead, a
-- player, or unreadable. Unit identity can be secret on this client, and a
-- secret throws when it is compared or truth-tested, not only when read - so
-- every touch happens inside the pcall. An unreadable unit is never treated
-- as "not on the list"; it simply isn't a sighting.
local function ReadNPCUnsafe(unit)
    if not UnitExists(unit) then return nil end
    local n = UnitName(unit)
    if IsSecret(n) or n == nil then return nil end
    -- Players, and anything a player controls (a pet named like a rare).
    if UnitIsPlayer(unit) or UnitPlayerControlled(unit) or UnitIsDead(unit) then return nil end
    local g = UnitGUID(unit)
    if IsSecret(g) then g = nil end
    return n, g
end

local function ReadNPC(unit)
    local ok, name, guid = pcall(ReadNPCUnsafe, unit)
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

local BUTTONS_PER_ROW = 5
local BUTTON_SIZE     = 26
local BUTTON_PAD      = 2
local HEADER_HEIGHT   = 16
local LABEL_HEIGHT    = 9    -- the name under a quest button (groups 2 and 3)

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

    -- Built now, before the frame has any secure button: the glass is never
    -- touched again, and follows the frame's size through its anchors.
    if not Theme.Window(f, { small = true, header = HEADER_HEIGHT }) then
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)
    end

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

-- How far the button's NPC is (Range.lua), while a token still shows it.
local function DistanceText(btn)
    local range = ns.range
    if not (range and btn.unit and ReadNPC(btn.unit) == btn.npcName) then return nil end
    local ok, text = pcall(range.Text, btn.unit)
    return ok and text or nil
end

-- While a button's tooltip is up, the distance is read again twice a second,
-- and the tooltip rebuilt only when it changed. A plain frame, never the
-- protected button: its scripts can't change in combat.
local tooltipRefresh = CreateFrame("Frame")
tooltipRefresh:Hide()

local function BtnOnEnter(self)
    if self:IsForbidden() or not self.npcName then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    if self.tooltipLines then
        -- A quest target: its own lines (quest titles, progress, the clicks).
        if self.friendly then
            GameTooltip:AddLine(self.npcName, 0.2, 1, 0.2)
        else
            GameTooltip:AddLine(self.npcName, 1, 0.2, 0.2)
        end
    else
        GameTooltip:AddLine(self.npcName, 1, 0.2, 0.2)
    end
    local distance = DistanceText(self)
    if distance then GameTooltip:AddLine("Distance: " .. distance, 1, 1, 1) end
    if self.tooltipLines then
        for _, line in ipairs(self.tooltipLines) do GameTooltip:AddLine(line, 0.7, 0.7, 0.7) end
    else
        GameTooltip:AddLine("Left-click: target", 0.7, 0.7, 0.7)
        if StakeoutDB.enableMarking then
            GameTooltip:AddLine("Right-click: target and mark (again: clear the mark)", 0.7, 0.7, 0.7)
        end
    end
    GameTooltip:Show()
    tooltipRefresh.button, tooltipRefresh.distance, tooltipRefresh.elapsed = self, distance, 0
    tooltipRefresh:Show()
end

local function BtnOnLeave()
    tooltipRefresh.button = nil
    tooltipRefresh:Hide()
    GameTooltip:Hide()
end

tooltipRefresh:SetScript("OnUpdate", function(f, elapsed)
    f.elapsed = (f.elapsed or 0) + (elapsed or 0)
    if f.elapsed < 0.5 then return end
    f.elapsed = 0
    local btn = f.button
    if not (btn and btn:IsShown()) then
        f:Hide()
    elseif DistanceText(btn) ~= f.distance then
        BtnOnEnter(btn)
    end
end)

-- The watch list shows a button for every detected name.
local function IsWatchDisplayed(name)
    return detected[name] ~= nil
end

-- What the frame should show, in order: group 1 is the watch list (as it has
-- always been), then the quest targets Quests.lua asks for, friendlies (group
-- 2) before enemies (group 3). A quest name the watch list already shows is
-- left to the watch list; one that isn't shown there yet gets its own button.
local function DesiredButtons()
    local list = {}
    local names = {}
    for name in pairs(detected) do tinsert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        -- /targetexact can pick a corpse of the name when no live one is in
        -- reach; /cleartarget [dead] then leaves no target instead (the
        -- `corpse` probe, FOREVER-PROBE.md; with a live one in reach it
        -- targets that one). The mark that follows needs a target, so a
        -- corpse is never marked either.
        local target = fmt("/cleartarget\n/targetexact %s\n/cleartarget [dead]", name)
        local entry = { group = 1, name = name, unit = detected[name].unitId, macrotext = target }
        -- SetRaidTarget is forbidden to addon code here, so the mark is the
        -- player's click: right-click targets and marks in one press.
        if StakeoutDB.enableMarking then
            entry.macrotext2 = fmt("%s\n/tm %d", target, StakeoutDB.markerIndex)
        end
        list[#list + 1] = entry
    end

    local quests = ns.quests
    local specs = quests and type(quests.ButtonSpecs) == "function" and quests.ButtonSpecs() or nil
    if type(specs) ~= "table" then return list end
    local taken = {}
    for _, group in ipairs({ { row = "friendly", n = 2 }, { row = "enemy", n = 3 } }) do
        for _, spec in ipairs(specs) do
            local row = spec.row == "friendly" and "friendly" or "enemy"
            if row == group.row and MacroSafeName(spec.name) and type(spec.macrotext) == "string"
                and not taken[spec.name] and not IsWatchDisplayed(spec.name) then
                taken[spec.name] = true
                list[#list + 1] = {
                    group = group.n, name = spec.name, unit = spec.unit, icon = spec.icon,
                    macrotext = spec.macrotext, macrotext2 = spec.macrotext2,
                    tooltip = spec.tooltip, friendly = row == "friendly",
                }
            end
        end
    end
    return list
end

-- Everything a layout writes to the protected frame: the order, the groups,
-- the names and both macros. Portraits and tooltips are not in it.
local function Signature(list)
    local parts = {}
    for i, e in ipairs(list) do
        parts[i] = table.concat({ e.group, e.name, e.macrotext, e.macrotext2 or "" }, "\31")
    end
    return table.concat(parts, "\30")
end

local function NewButton(i)
    local btn = CreateFrame("Button", "StakeoutBtn" .. i, targetFrame, "SecureActionButtonTemplate")
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
    btn.highlight = ht

    -- A quest button's name, under it: placed by ApplyLayout, written by
    -- UpdateButtonLooks. A watch button's is empty: the player typed those.
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.label:SetFontHeight(8)
    btn.label:SetWordWrap(false)
    -- Only ever made by ApplyLayout, which runs out of combat.
    Theme.Button(btn)

    btn:SetScript("OnEnter", BtnOnEnter)
    btn:SetScript("OnLeave", BtnOnLeave)

    tinsert(targetButtons, btn)
    return btn
end

-- The secure part: sizes, anchors, attributes, shown and hidden. Every
-- attribute is written for every button, so one that changes role (a watch
-- name, then a quest target) keeps nothing from the old one.
local function ApplyLayout(list)
    for _, btn in ipairs(targetButtons) do btn:Hide() end
    if #list == 0 then
        targetFrame:Hide()
        return
    end

    -- Each group starts a new line, and a line holds BUTTONS_PER_ROW. A quest
    -- line is taller by its labels.
    local spots, line, col, cols, group = {}, -1, BUTTONS_PER_ROW, 0, nil
    local y, lineHeight = 0, 0
    for i, e in ipairs(list) do
        if e.group ~= group or col == BUTTONS_PER_ROW then
            y = y + lineHeight
            line, col, group = line + 1, 0, e.group
            lineHeight = BUTTON_SIZE + BUTTON_PAD + (e.group > 1 and LABEL_HEIGHT or 0)
        end
        spots[i] = { line = line, col = col, y = y }
        col = col + 1
        cols = math.max(cols, col)
    end
    local pitch  = BUTTON_SIZE + BUTTON_PAD
    local width  = math.max(cols * pitch + BUTTON_PAD + 8, 90)
    local height = HEADER_HEIGHT + y + lineHeight + BUTTON_PAD + 4
    targetFrame:SetSize(width, height)

    for i, e in ipairs(list) do
        local btn = targetButtons[i] or NewButton(i)
        local x = 6 + spots[i].col * pitch
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", targetFrame, "TOPLEFT", x, -(HEADER_HEIGHT + 2 + spots[i].y))
        -- A label fits under its own button, except the last of a line, whose
        -- label runs to the frame's edge: a lone "Kul Tiras Sailor" fits whole.
        btn.label:ClearAllPoints()
        if not spots[i + 1] or spots[i + 1].line ~= spots[i].line then
            btn.label:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -1)
            btn.label:SetWidth(width - x - 4)
            btn.label:SetJustifyH("LEFT")
        else
            btn.label:SetPoint("TOP", btn, "BOTTOM", 0, -1)
            btn.label:SetWidth(pitch)
            btn.label:SetJustifyH("CENTER")
        end
        -- The key mechanic: a secure macro targets the NPC by exact name.
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", e.macrotext)
        if e.macrotext2 then
            btn:SetAttribute("type2", "macro")
            btn:SetAttribute("macrotext2", e.macrotext2)
        else
            -- No right-click action: the secure handler falls back to "type".
            btn:SetAttribute("type2", nil)
            btn:SetAttribute("macrotext2", nil)
        end
        btn:Show()
    end
    targetFrame:Show()
end

-- A quest button's label: its name without the words it shares with another
-- quest button's ("Kul Tiras Sailor" and "Kul Tiras Marine" read "Sailor" and
-- "Marine"), or the whole name when nothing would be left. By words, so no
-- language's own rules are assumed.
local function ShortLabel(name, others)
    local shared = {}
    for _, other in ipairs(others) do
        if other ~= name then
            for word in other:gmatch("%S+") do shared[word] = true end
        end
    end
    local kept = {}
    for word in name:gmatch("%S+") do
        if not shared[word] then kept[#kept + 1] = word end
    end
    return #kept > 0 and table.concat(kept, " ") or name
end

-- The insecure part, on every refresh: who each button is for, its tooltip,
-- its label and its picture. The picture is the NPC's portrait while a unit
-- token shows it, and stays while the button lingers after that (the portrait
-- is of that NPC, at most LINGER seconds old); otherwise the button's icon.
local function UpdateButtonLooks(list)
    local questNames = {}
    for _, e in ipairs(list) do
        if e.group > 1 then questNames[#questNames + 1] = e.name end
    end
    for i, e in ipairs(list) do
        local btn = targetButtons[i]
        btn.npcName = e.name
        btn.unit = e.unit
        btn.tooltipLines = e.tooltip
        btn.friendly = e.friendly
        if e.unit and ReadNPC(e.unit) == e.name then
            SetPortraitTexture(btn.icon, e.unit)
            btn.portraitOf = e.name
        elseif btn.portraitOf ~= e.name then
            btn.icon:SetTexture(e.icon or GetButtonIcon())
            btn.portraitOf = nil
        end
        btn.label:SetText(e.group > 1 and ShortLabel(e.name, questNames) or "")
    end
end

-- The signature of the layout on the frame now: nil until one is applied. A
-- refresh that wanted a change in combat applies nothing and leaves it alone.
local lastApplied
local pendingRefresh = false

local function RenderTargetFrame()
    local list = DesiredButtons()
    local signature = Signature(list)
    if signature ~= lastApplied then
        ApplyLayout(list)
        lastApplied = signature
    end
    UpdateButtonLooks(list)
end

-- Every change to the buttons comes through here. The frame is protected, so
-- in combat this only notes that a refresh is owed; OnCombatEnd refreshes.
local function RefreshTargetFrame()
    if not targetFrame then return end
    if InCombatLockdown() then
        pendingRefresh = true
        return
    end
    pendingRefresh = false
    RenderTargetFrame()
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
-- An NPC that left stays quiet this long before it can alert again, so a
-- plate flickering at the edge of range doesn't alert over and over. A death
-- re-arms it at once.
local REARM = 60

-- GUID -> name for every watched NPC seen this session. Outlives the entry,
-- so a UNIT_DIED that arrives after the plate is gone still re-arms the alert.
local seenGUIDs = {}

-- announced[name]: nil = armed; a number = quiet until that time; true = the
-- alert for the current detection has played.
local function Alert(name)
    local quiet = announced[name]
    if quiet == true or (quiet and GetTime() < quiet) then return end
    announced[name] = true
    Print("Detected: %s", name)
    if StakeoutDB.flashOnFind then FlashClientIcon() end
    if StakeoutDB.soundOnFind then PlayAlertSound() end
end

-- A detection ends: quiet for REARM, then the next sighting alerts again.
-- One that saw a death re-arms at once instead.
local function EndDetection(name)
    local entry = detected[name]
    detected[name] = nil
    announced[name] = not (entry and entry.sawDeath) and (GetTime() + REARM) or nil
end

local function Sighted(name, guid, unit, isPlate)
    local entry = detected[name]
    local isNew = not entry
    if isNew then
        entry = { plates = {}, guids = {} }
        detected[name] = entry
    end
    if guid then
        entry.guids[guid] = true
        seenGUIDs[guid] = name
    end
    if isPlate then entry.plates[unit] = guid or true end
    entry.unitId = unit
    entry.lastSeen = GetTime()
    -- Only a new name changes the buttons; rebuilding on every mouseover
    -- would also hide the tooltip of a hovered button.
    if isNew then
        RefreshTargetFrame()
        Alert(name)
    end
end

local function CheckUnit(unit, isPlate)
    local name, guid = ReadNPC(unit)
    if name and IsInNPCList(name) then
        Sighted(name, guid, unit, isPlate)
    end
    -- Quest targets see every unit, watched or not (Quests.lua, when loaded).
    local quests = ns.quests
    if quests and quests.OnUnit then quests.OnUnit(unit, isPlate, name, guid) end
end

-- Everything that counts as presence: the plates, the target, the mouseover.
local function Rescan()
    for _, plate in ipairs(GetNamePlates() or {}) do
        if plate.namePlateUnitToken then CheckUnit(plate.namePlateUnitToken, true) end
    end
    CheckUnit("target", false)
    CheckUnit("mouseover", false)
end

-- The target or mouseover shows a live NPC of this name right now.
local function StillVisible(name)
    return ReadNPC("target") == name or ReadNPC("mouseover") == name
end

-- Drop plate tokens that no longer show the NPC (a missed
-- NAME_PLATE_UNIT_REMOVED must not keep a button forever), then entries with
-- no plate that neither the target nor the mouseover shows and that were last
-- seen more than LINGER seconds ago.
local function Sweep()
    local now, changed = GetTime(), false
    for name, entry in pairs(detected) do
        local hadPlates = next(entry.plates) ~= nil
        for token in pairs(entry.plates) do
            if ReadNPC(token) ~= name then entry.plates[token] = nil end
        end
        if hadPlates and not next(entry.plates) then entry.lastSeen = 0 end
        if not next(entry.plates) then
            if StillVisible(name) then
                entry.lastSeen = now
            elseif now - (entry.lastSeen or 0) > LINGER then
                EndDetection(name)
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
    local quests = ns.quests
    if quests and quests.OnPlateRemoved then quests.OnPlateRemoved(token) end
end

local function UnitDied(guid)
    -- IsSecret first: comparing a secret, even to nil, throws.
    if IsSecret(guid) or guid == nil then return end
    -- A watched NPC died, whether or not it is still detected: its respawn
    -- should alert.
    local diedName = seenGUIDs[guid]
    if diedName then
        seenGUIDs[guid] = nil
        if not detected[diedName] then announced[diedName] = nil end
    end
    local changed = false
    for name, entry in pairs(detected) do
        if entry.guids[guid] then
            entry.guids[guid] = nil
            entry.sawDeath = true
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
    local quests = ns.quests
    if quests and quests.OnUnitDied then quests.OnUnitDied(guid) end
end

-- The 1 s ticker: the watch list's expiry, then the quest targets' own.
local function Tick()
    Sweep()
    local quests = ns.quests
    if quests and quests.Tick then quests.Tick() end
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
    Rescan()
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

-- The first `bytes` bytes of a UTF-8 string, never cutting a character.
local function Clip(text, bytes)
    local clipped = text:sub(1, bytes)
    -- Drop a trailing multibyte character only if the cut left it incomplete.
    local lead = clipped:find("[\192-\255][\128-\191]*$")
    if lead then
        local b = clipped:byte(lead)
        local length = (b >= 240 and 4) or (b >= 224 and 3) or 2
        if #clipped - lead + 1 < length then clipped = clipped:sub(1, lead - 1) end
    end
    return clipped
end

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

local function ExportLines(list, maxLen)
    maxLen = maxLen or MACRO_LINE_MAX
    local lines, current = {}, nil
    for _, name in ipairs(list) do
        -- A longer name can't fit a line at all. AddNames refuses them; this
        -- covers lists that arrive another way (a macro, SavedVariables).
        if #name <= NAME_MAX then
            local candidate = current and (current .. "; " .. name) or (EXPORT_PREFIX .. name)
            if current and #candidate > maxLen then
                lines[#lines + 1] = current
                candidate = EXPORT_PREFIX .. name
            end
            current = candidate
        end
    end
    if current then lines[#lines + 1] = current end
    return lines
end

local RefreshNPCList   -- defined with the config GUI

-------------------------------------------------------------------------------
-- The watch list in character macros
--
-- SavedVariables never load back on this client, but character macros survive
-- a restart (#2). Once the player turns this on (/stakeout macro on, or the
-- config checkbox), every change to the list is written into character macros
-- named "Stakeout List", "Stakeout List 2", ... and read back at login. Each
-- body is the marker line, then one `/stakeout add` line, so clicking one
-- works too: macro lines starting with "#" are ignored when it runs.
--
-- Whether the macro exists IS the setting: it is the only state that survives
-- a restart, so turning this off deletes the macros.
--
-- Ownership is the MACRO_MARK first line, never the name or a `/stakeout add`
-- body: players are told to paste export lines into macros of their own, and
-- the client allows two macros with one name (measured). Character macros are
-- scanned one by one rather than trusting GetMacroIndexByName, which returns
-- only one of several same-named macros. A macro that isn't ours is never
-- edited or deleted.
-------------------------------------------------------------------------------
local MACRO_NAMES = { "Stakeout List", "Stakeout List 2", "Stakeout List 3" }
local MACRO_ICON  = "INV_MISC_QUESTIONMARK"
local MACRO_MARK  = "#stakeout"
local MACRO_EMPTY = MACRO_MARK      -- an empty list keeps the macro (the setting)
local MACRO_ADD_MAX = MACRO_LINE_MAX - #MACRO_MARK - 1
local CHARACTER_MACRO_FIRST = 121   -- measured: character macros follow 120 account slots
local macroMode = false             -- mirror the list into the macros
local macroSyncPending = false      -- a change made in combat, written when it ends
local macrosRestored = false        -- the login restore found our macro (or we own it now)
-- Whether the client has loaded the character macros. Until it has, no macro
-- is written: one created early would be a twin of the real one still
-- loading, and folding the two later can resurrect names the player removed.
local macrosKnown = false
local macroOnPending = false        -- `macro on` asked for before the macros loaded

local function IsOurBody(body)
    return type(body) == "string" and
        (body == MACRO_MARK or body:sub(1, #MACRO_MARK + 1) == MACRO_MARK .. "\n")
end

-- Every character macro with this name: the indices of ours (ascending), and
-- whether one that isn't ours has it too.
local function FindMacros(name)
    local ours, foreign = {}, false
    local ok, _, numCharacter = pcall(GetNumMacros)
    if not ok or type(numCharacter) ~= "number" then return ours, foreign end
    for idx = CHARACTER_MACRO_FIRST, CHARACTER_MACRO_FIRST + numCharacter - 1 do
        local okInfo, macroName = pcall(GetMacroInfo, idx)
        if okInfo and macroName == name then
            local okBody, body = pcall(GetMacroBody, idx)
            if okBody and IsOurBody(body) then ours[#ours + 1] = idx else foreign = true end
        end
    end
    return ours, foreign
end

local function WriteMacro(name, body)
    local ours, foreign = FindMacros(name)
    if ours[1] then
        -- Extra copies of ours go, highest index first so ours[1] stays valid.
        for k = #ours, 2, -1 do pcall(DeleteMacro, ours[k]) end
        return (pcall(EditMacro, ours[1], nil, nil, body))
    end
    -- One of the player's own holds the name: don't add a confusing twin.
    if foreign then return false end
    local ok, created = pcall(CreateMacro, name, MACRO_ICON, body, true)
    return ok and created ~= nil and created ~= 0
end

local function DeleteOurMacros(name)
    local ours = FindMacros(name)
    for k = #ours, 1, -1 do pcall(DeleteMacro, ours[k]) end
end

-- Macro warnings are printed when their kind changes, not on every list
-- change (the overflow text names the left-out NPCs, so it changes on
-- every add).
local lastMacroWarning
local function MacroWarning(kind, text)
    if kind and kind ~= lastMacroWarning then Print(text) end
    lastMacroWarning = kind
end

-- Merge the names in every copy of our macros into the list; returns how many
-- were new. Reading every copy matters: the client allows duplicate names.
local function MergeMacroNames()
    local added = 0
    for _, name in ipairs(MACRO_NAMES) do
        for _, idx in ipairs((FindMacros(name))) do
            local ok, body = pcall(GetMacroBody, idx)
            if ok and type(body) == "string" then
                for line in (body .. "\n"):gmatch("([^\n]*)\n") do
                    local rest = line:match("^%s*/stakeout add%s+(.+)$")
                    if rest then
                        for _, n in ipairs(ParseNames(rest)) do
                            if #n <= NAME_MAX and AddNPC(n) then added = added + 1 end
                        end
                    end
                end
            end
        end
    end
    return added
end

-- Write the list into the macros. Returns true when Stakeout List holds it.
local function SyncMacros()
    if not macroMode then return false end
    -- Macros can't be written in combat; the change is written when it ends.
    -- Said once, because a session that ends before combat does loses it.
    if InCombatLockdown() then
        if not macroSyncPending then
            Print("The Stakeout List macro will be updated when combat ends.")
        end
        macroSyncPending = true
        return false
    end
    macroSyncPending = false

    local lines = ExportLines(StakeoutDB.npcList, MACRO_ADD_MAX)
    -- The first macro is the setting. If it can't be written, write none: a
    -- "Stakeout List 2" alone would take a slot and never be read or updated.
    local first = lines[1] and (MACRO_MARK .. "\n" .. lines[1]) or MACRO_EMPTY
    if not WriteMacro(MACRO_NAMES[1], first) then
        for i = 2, #MACRO_NAMES do DeleteOurMacros(MACRO_NAMES[i]) end
        MacroWarning("blocked", "|cffff6666Couldn't write the Stakeout List macro.|r Your character macro slots may be " ..
            "full, or one of yours already uses that name.")
        return false
    end
    local failed = false
    for i = 2, #MACRO_NAMES do
        if lines[i] then
            if not WriteMacro(MACRO_NAMES[i], MACRO_MARK .. "\n" .. lines[i]) then failed = true end
        else
            DeleteOurMacros(MACRO_NAMES[i])
        end
    end

    local kind, warning
    if failed then
        kind = "partial"
        warning = "|cffff6666Couldn't write all the Stakeout List macros|r (character macro slots full?); " ..
            "part of the list won't come back after a restart."
    elseif #lines > #MACRO_NAMES then
        local left = {}
        for i = #MACRO_NAMES + 1, #lines do
            for _, n in ipairs(ParseNames(lines[i]:sub(#EXPORT_PREFIX + 1))) do left[#left + 1] = n end
        end
        kind = "overflow"
        warning = fmt("|cffffcc00Too many NPCs for %d macros; these won't come back after a restart:|r %s",
            #MACRO_NAMES, table.concat(left, ", "))
    end
    MacroWarning(kind, warning)
    return true
end

-- Adopt our macro if it is there: merge its names into the list, turn macro
-- mode on, and write back any names added before it was found (macros can
-- load after login). Returns whether it was there.
local function RestoreFromMacros()
    if not FindMacros(MACRO_NAMES[1])[1] then return false end
    macroMode = true
    macrosRestored = true
    local added = MergeMacroNames()
    if added > 0 then
        Print("Restored %d NPC%s from your Stakeout List macro.", added, added == 1 and "" or "s")
        Rescan()
    end
    RefreshNPCList()
    SyncMacros()
    return true
end

-- Returns whether macro mode is on afterwards.
local function SetMacroMode(on)
    if InCombatLockdown() then
        Print("Macros can't be changed in combat; try again when it ends.")
        return macroMode
    end
    if on and not macrosKnown then
        macroOnPending = true
        Print("Your macros haven't loaded yet; Stakeout will turn this on as soon as they have.")
        return macroMode
    end
    if on then
        -- A macro of ours may already be there: adopt it and merge, rather
        -- than write over it.
        if not RestoreFromMacros() then
            macroMode = true
            macroMode = SyncMacros()
            macrosRestored = macroMode
        end
        if macroMode then
            Print("Your watch list is now kept in the character macro |cff00ff00Stakeout List|r and " ..
                "comes back by itself at login.")
        end
    else
        macroMode = false
        macroOnPending = false
        lastMacroWarning = nil
        for _, name in ipairs(MACRO_NAMES) do DeleteOurMacros(name) end
        Print("Stopped keeping the watch list in a macro; the Stakeout List macros were deleted.")
    end
    RefreshNPCList()
    return macroMode
end

-- Carry out a `macro on` that waited for the macros to load - and, if they
-- loaded in combat, for combat to end: it stays pending until it can run.
local function ApplyPendingMacroOn()
    if not macroOnPending or not macrosKnown or InCombatLockdown() then return end
    macroOnPending = false
    SetMacroMode(true)
end

local function AddNames(text)
    local added, already = {}, {}
    for _, name in ipairs(ParseNames(text)) do
        if #name > NAME_MAX then
            Print("|cffff6666Too long to be an NPC name (over %d characters):|r %s...", NAME_MAX, Clip(name, 40))
        elseif AddNPC(name) then
            added[#added + 1] = name
        else
            already[#already + 1] = name
        end
    end
    if #added > 0 then
        Print("|cff00ff00Added:|r %s  (total: %d)", table.concat(added, ", "), #StakeoutDB.npcList)
        Rescan()
        RefreshNPCList()
        SyncMacros()
    end
    if #already > 0 then
        Print("|cffff6666Already listed:|r %s", table.concat(already, ", "))
    end
    return #added
end

-- One flow each for the slash commands and the config buttons.
local function RemoveWatched(name)
    if not RemoveNPC(name) then return false end
    ForgetNPC(name)
    RefreshNPCList()
    SyncMacros()
    Print("|cffff6666Removed:|r %s", name)
    return true
end

local function ClearWatchList()
    ClearNPCs()
    ResetDetections()
    RefreshNPCList()
    SyncMacros()
    Print("NPC list cleared.")
end

-- The beta's chat frame cannot be copied from, so exports go into a
-- selectable box: select one line, Ctrl+C, paste it into its own macro.
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
        -- The config window opens it, in the same strata, and comes forward
        -- when its Export button is clicked: this one does too, and is raised
        -- over it each time it opens.
        f:SetToplevel(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        -- The title row ends where the text starts (34 px down).
        if not Theme.Window(f, { header = 22 }) then
            f:SetBackdrop({
                bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 14,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
        end
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 14, -12)
        Theme.Accent(title)
        title:SetText("Stakeout watch list - one macro per line (each fits 255 characters)")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        local scroll = CreateFrame("ScrollFrame", "StakeoutExportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -34)
        scroll:SetPoint("BOTTOMRIGHT", -34, 14)
        Theme.Reading(f, scroll, 4)
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
    -- A macro holds 255 characters, so each line is its own macro; the blank
    -- lines make the boundaries obvious when selecting one.
    exportFrame.eb:SetText(table.concat(lines, "\n\n"))
    exportFrame:Show()
    exportFrame:Raise()
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
            row.label:SetWidth(250)
            row.label:SetWordWrap(false)

            row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
            row.deleteBtn:SetSize(20, 20)
            row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            row.deleteBtn:SetScript("OnClick", function()
                if row.npcName then RemoveWatched(row.npcName) end
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

    local count = #StakeoutDB.npcList
    if configFrame.countLabel then configFrame.countLabel:SetText(fmt("%d tracked", count)) end
    if configFrame.emptyTitle then
        configFrame.emptyTitle:SetShown(count == 0)
        configFrame.emptyHint:SetShown(count == 0)
    end
    if configFrame.macroCheck then configFrame.macroCheck:SetChecked(macroMode) end
end

-- Save a look (the config's dropdown, /stakeout look). The windows keep the
-- one they were built in until a /reload.
local function ChooseLook(look)
    SetConfig("theme", look)
    if Theme.Following() then
        Print("Look: %s, kept for when Stakeout doesn't follow Glass UI.", Theme.LABELS[look])
    elseif look == Theme.Active() then
        Print("Look: %s (the one in use).", Theme.LABELS[look])
    else
        Print("Look: %s. Type |cff00ff00/reload|r to apply it.", Theme.LABELS[look])
    end
end

-- The config window (#34): the watch list on the left, the settings on the
-- right. Each column is laid out down a y cursor, in px from the window's top.
local CFG_W, CFG_H = 712, 540
local COL_W = 324
local LEFT, RIGHT = 16, 372   -- the columns' left edges
local TOP = -50               -- where both columns start, under the title row
local CHECK = 26              -- a checkbox's size; its art is about two thirds of it (FOREVER-PROBE.md §13)

local function Rule(parent, x, y, width)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    t:SetSize(width, 1)
    t:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    return t
end

local function SectionTitle(parent, x, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    Theme.Accent(fs)
    return fs
end

-- A row's label, its left edge at x and its middle at y.
local function RowLabel(parent, x, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

-- A checkbox with its label in white and, optionally, a line under the label
-- in grey. Takes 30 px down, or 44 with the line.
local function Check(parent, x, y, label, desc)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(CHECK, CHECK)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local text = cb.text or cb.Text
    if text then
        text:SetFontObject("GameFontHighlight")
        text:SetText(label)
    end
    if desc then
        cb.desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        if text then
            cb.desc:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -3)
        else
            cb.desc:SetPoint("TOPLEFT", cb, "BOTTOMRIGHT", 2, 2)
        end
        cb.desc:SetText(desc)
    end
    return cb
end

-- Helper: create a labeled checkbox bound to a setting
local function MakeCheckbox(parent, x, y, label, dbKey, onChange, desc)
    local cb = Check(parent, x, y, label, desc)
    cb:SetChecked(StakeoutDB[dbKey])
    cb:SetScript("OnClick", function(self)
        SetConfig(dbKey, self:GetChecked() and true or false)
        if onChange then onChange(StakeoutDB[dbKey]) end
    end)
    return cb
end

-- A row of picture buttons, the chosen one lit. entries: { texture, name }.
local function MakePicker(parent, x, y, entries, chosen, onPick)
    local buttons = {}
    for idx, entry in ipairs(entries) do
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(26, 26)
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", x + (idx - 1) * 30, y)

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints(true)
        b.icon:SetTexture(entry.texture)

        b.selected = b:CreateTexture(nil, "OVERLAY")
        b.selected:SetPoint("TOPLEFT", -2, 2)
        b.selected:SetPoint("BOTTOMRIGHT", 2, -2)
        b.selected:SetColorTexture(1, 1, 1, 0.25)
        b.selected:Hide()

        b.ht = b:CreateTexture(nil, "HIGHLIGHT")
        b.ht:SetAllPoints(true)
        b.ht:SetColorTexture(1, 1, 1, 0.15)

        b:SetScript("OnClick", function()
            for _, other in ipairs(buttons) do other.selected:Hide() end
            b.selected:Show()
            onPick(idx, entry)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(entry.name, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)

        if chosen == idx then b.selected:Show() end
        buttons[idx] = b
    end
    return buttons
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

    -- The Glass UI switch only means something with Glass UI loaded.
    local suiteRow = Theme.SuiteAvailable()
    local height = CFG_H + (suiteRow and 44 or 0)
    f:SetSize(CFG_W, height)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    -- The title row ends at the rule under it (40 px down).
    if not Theme.Window(f, { header = 40 }) then
        MakeBackdrop(f, 16, { left = 4, right = 4, top = 4, bottom = 4 },
            { 0.08, 0.08, 0.10, 0.95 }, { 0.4, 0.4, 0.4, 1 })
    end

    f:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("|cff33ccffStakeout|r")

    Rule(f, 14, -40, CFG_W - 28)
    -- Between the columns, from under the title row to the bottom.
    local split = f:CreateTexture(nil, "ARTWORK")
    split:SetPoint("TOPLEFT", f, "TOPLEFT", RIGHT - 16, TOP)
    split:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", RIGHT - 16, 16)
    split:SetWidth(1)
    split:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    ---------------------------------------------------------------------------
    -- Left: the watch list
    ---------------------------------------------------------------------------
    local y = TOP
    SectionTitle(f, LEFT, y, "Watch list")

    f.countLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.countLabel:SetPoint("TOPRIGHT", f, "TOPLEFT", LEFT + COL_W, y - 4)

    y = y - 28
    local addBox = CreateFrame("EditBox", "StakeoutAddBox", f, "BackdropTemplate")
    addBox:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, y)
    addBox:SetSize(COL_W - 98, 26)
    addBox:SetFontObject("ChatFontNormal")
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(255)
    if not Theme.Control(addBox) then
        MakeBackdrop(addBox, 12, { left = 4, right = 4, top = 2, bottom = 2 },
            { 0.1, 0.1, 0.12, 0.9 }, { 0.5, 0.5, 0.5, 0.8 })
    end
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
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 8, 0)
    addBtn:SetSize(90, 26)
    addBtn:SetText("Add NPC")

    local function DoAddNPC()
        if AddNames(addBox:GetText()) > 0 then
            addBox:SetText("")
            addBox:ClearFocus()
        end
    end
    addBtn:SetScript("OnClick", DoAddNPC)
    addBox:SetScript("OnEnterPressed", DoAddNPC)

    y = y - 32
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT + 2, y)
    hint:SetText("Separate multiple names with semicolons.")

    -- From the bottom up: the macro checkbox and its line, then the buttons.
    local macroY = -(height - 16 - 40)
    local buttonsY = macroY + 36

    -- The list fills the space between the hint and the buttons.
    y = y - 18
    local scrollParent = CreateFrame("Frame", nil, f, "BackdropTemplate")
    scrollParent:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, y)
    scrollParent:SetSize(COL_W, y - buttonsY - 10)
    if not Theme.Reading(scrollParent) then
        MakeBackdrop(scrollParent, 12, { left = 2, right = 2, top = 2, bottom = 2 },
            { 0.04, 0.04, 0.06, 0.8 }, { 0.3, 0.3, 0.3, 0.8 })
    end

    local scrollFrame = CreateFrame("ScrollFrame", "StakeoutScrollFrame",
        scrollParent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", scrollParent, "BOTTOMRIGHT", -24, 4)

    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetSize(COL_W - 28, 1)
    scrollFrame:SetScrollChild(scrollContent)
    f.scrollContent = scrollContent

    -- Shown while the list is empty (RefreshNPCList).
    f.emptyTitle = scrollParent:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.emptyTitle:SetPoint("CENTER", scrollParent, "CENTER", 0, 10)
    f.emptyTitle:SetText("No NPCs tracked")
    f.emptyHint = scrollParent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.emptyHint:SetPoint("TOP", f.emptyTitle, "BOTTOM", 0, -6)
    f.emptyHint:SetText("Add an exact NPC name above to start watching.")

    -- Reset detections / Export / Clear list, the column's width together.
    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, buttonsY)
    resetBtn:SetSize(130, 26)
    resetBtn:SetText("Reset detections")
    resetBtn:SetScript("OnClick", function()
        ResetDetections()
        Print("Detections reset.")
    end)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
    exportBtn:SetSize(90, 26)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", ShowExport)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    clearBtn:SetSize(COL_W - 130 - 90 - 12, 26)
    clearBtn:SetText("Clear list")
    clearBtn:SetScript("OnClick", function()
        StaticPopupDialogs["STAKEOUT_CLEAR_CONFIRM"] = {
            text = "Remove all NPCs from the watch list?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = ClearWatchList,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("STAKEOUT_CLEAR_CONFIRM")
    end)

    -- Not a StakeoutDB setting: the macro's existence is the setting.
    local macroCheck = Check(f, LEFT, macroY, "Save list in a character macro",
        "Restores the list when you log in.")
    macroCheck:SetScript("OnClick", function(self)
        self:SetChecked(SetMacroMode(self:GetChecked() and true or false))
    end)
    f.macroCheck = macroCheck

    ---------------------------------------------------------------------------
    -- Right: the settings
    ---------------------------------------------------------------------------
    local x = RIGHT
    y = TOP
    SectionTitle(f, x, y, "Alerts")

    y = y - 26
    MakeCheckbox(f, x, y, "Flash taskbar on detection", "flashOnFind")
    y = y - 30
    MakeCheckbox(f, x, y, "Play sound on detection", "soundOnFind")

    y = y - 32
    RowLabel(f, x + 4, y - 14, "Sound")
    local soundDropdown = CreateFrame("Frame", "StakeoutSoundDropdown", f, "UIDropDownMenuTemplate")
    soundDropdown:SetPoint("LEFT", f, "TOPLEFT", x + 44, y - 14)
    UIDropDownMenu_SetWidth(soundDropdown, 220)

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

    y = y - 40
    Rule(f, x, y, COL_W)
    y = y - 12
    SectionTitle(f, x, y, "Raid marking")

    y = y - 26
    MakeCheckbox(f, x, y, "Right-click to target and mark", "enableMarking",
        function() RefreshTargetFrame() end, "On a tracked NPC button.")

    y = y - 44
    RowLabel(f, x + 4, y - 13, "Marker")
    local markers = {}
    for i = 1, 8 do markers[i] = { texture = MARKER_ICONS[i], name = MARKER_NAMES[i] } end
    MakePicker(f, x + 60, y, markers, StakeoutDB.markerIndex, function(idx)
        SetConfig("markerIndex", idx)
        RefreshTargetFrame()
        Print("Marker set to: %s", MARKER_NAMES[idx])
    end)

    y = y - 36
    Rule(f, x, y, COL_W)
    y = y - 12
    SectionTitle(f, x, y, "Target frame")

    y = y - 26
    MakeCheckbox(f, x, y, "Lock frame position", "lockFrame", nil, "Alt + drag overrides the lock.")

    y = y - 44
    local iconLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    iconLabel:SetPoint("TOPLEFT", f, "TOPLEFT", x + 4, y)
    iconLabel:SetText("Button icon")
    y = y - 18
    MakePicker(f, x + 60, y, BUTTON_ICONS, StakeoutDB.buttonIcon or 1, function(idx, entry)
        SetConfig("buttonIcon", idx)
        RefreshTargetFrame()
        Print("Button icon set to: %s", entry.name)
    end)

    -- Scale: the label, its value at the column's right, the slider under them.
    y = y - 38
    local scaleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleLabel:SetPoint("TOPLEFT", f, "TOPLEFT", x + 4, y)
    scaleLabel:SetText("Scale")
    local scaleValue = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleValue:SetPoint("TOPRIGHT", f, "TOPLEFT", x + COL_W - 4, y)

    y = y - 20
    local slider = CreateFrame("Slider", "StakeoutScaleSlider", f, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", f, "TOPLEFT", x + 60, y)
    slider:SetWidth(COL_W - 68)
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
        scaleValue:SetText(fmt("%.0f%%", val))
    end
    UpdateScaleLabel(slider:GetValue())

    slider:SetScript("OnValueChanged", function(_, val)
        val = math.floor(val / 10 + 0.5) * 10
        SetConfig("frameScale", val / 100)
        -- The target frame is protected; rescale it once combat ends.
        if targetFrame and not InCombatLockdown() then targetFrame:SetScale(StakeoutDB.frameScale) end
        UpdateScaleLabel(val)
    end)

    -- Look: every window's, built in when it is made, so a choice applies
    -- after a /reload. The note says so while the choice isn't the one worn.
    y = y - 40
    RowLabel(f, x + 4, y - 14, "Look")
    local lookDropdown = CreateFrame("Frame", "StakeoutLookDropdown", f, "UIDropDownMenuTemplate")
    lookDropdown:SetPoint("LEFT", f, "TOPLEFT", x + 44, y - 14)
    UIDropDownMenu_SetWidth(lookDropdown, 120)

    local lookNote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lookNote:SetPoint("LEFT", lookDropdown, "RIGHT", -6, 2)

    local function ShowLook()
        local chosen = StoredLook()
        UIDropDownMenu_SetText(lookDropdown, Theme.LABELS[chosen])
        if Theme.Following() then
            lookNote:SetText("Glass UI's in use")
        else
            lookNote:SetText(chosen ~= Theme.Active() and "/reload to apply" or "")
        end
    end

    UIDropDownMenu_Initialize(lookDropdown, function()
        for _, look in ipairs(Theme.LOOKS) do
            local info   = UIDropDownMenu_CreateInfo()
            info.text    = Theme.LABELS[look]
            info.value   = look
            info.checked = (StoredLook() == look)
            info.func = function()
                ChooseLook(look)
                ShowLook()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    ShowLook()

    if suiteRow then
        y = y - 34
        local follow = MakeCheckbox(f, x, y, "Use Glass UI appearance", "followGlassUI", function(on)
            Print("%s Glass UI's look after a |cff00ff00/reload|r.", on and "Stakeout will wear" or "Stakeout won't wear")
        end, "Its glass, tint and accent; off, the look above.")
        f.followCheck = follow
    end

    -- ESC closes config
    if UISpecialFrames then tinsert(UISpecialFrames, "StakeoutConfigFrame") end

    RefreshNPCList()
    f:Show()
end

-------------------------------------------------------------------------------
-- Event frame
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

-- Character macros can load after PLAYER_LOGIN. The client has loaded them
-- once it reports any (a player with none at all gets the timer fallback).
local function MacrosLoaded()
    local ok, account, character = pcall(GetNumMacros)
    return ok and ((tonumber(account) or 0) + (tonumber(character) or 0)) > 0
end

-- Said once, and only once the macros are known: before that, a macro that
-- is about to load would be reported missing, and `/stakeout macro on` typed
-- in answer would race it.
local settingsNoticeShown = false
local function ShowSettingsNotice()
    if settingsNoticeShown then return end
    settingsNoticeShown = true
    if settingsLoaded or macroMode then return end
    Print("|cffffcc00This beta client doesn't reload saved settings (a Blizzard bug), so the watch " ..
        "list starts empty.|r Type |cff00ff00/stakeout macro on|r to keep it in a character macro " ..
        "that brings it back at every login.")
end

-- The macros are loaded (or, for a player with none, 15 s have passed): adopt
-- ours if it is there, say the settings notice if it still applies, and
-- carry out a `macro on` that had to wait.
local function OnMacrosKnown()
    if macrosKnown then return end
    macrosKnown = true
    if not macrosRestored then RestoreFromMacros() end
    ShowSettingsNotice()
    ApplyPendingMacroOn()
end

-- The build note is for whoever has to re-measure, not for players: a release
-- that still runs on a newer client gains nothing from being told it was tested
-- on an older one, and what flags an addon out of date is the TOC's Interface
-- number, not this. So it speaks only in a development copy - `dev` from
-- Tools/deploy.ps1, or the raw packager token in an unpackaged checkout - and
-- only once per build: lastBuild latches it, in SavedVariables, which load
-- again since 70009. Every copy records the build, so a dev copy deployed over
-- a release does not announce a patch the player already had.
--
-- The token is built from two pieces ON PURPOSE. The packager replaces it in
-- every file it ships, Lua included, so the whole literal here became
-- `version == "v2.1.1"` in the v2.1.1 release, and every player's copy counted
-- as a development copy (#17). tests/test_manifest.lua fails on the whole
-- literal in any shipped Lua file.
local UNPACKAGED_VERSION = "@" .. "project-version@"
local function IsDevelopmentCopy()
    local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
    return version == "dev" or version == UNPACKAGED_VERSION
end

local function OnLogin()
    local build = select(2, GetBuildInfo())
    RestoreFromMacros()
    Print("Loaded. |cff00ff00/stakeout|r to open config. Tracking %d NPCs.", #StakeoutDB.npcList)
    if macrosRestored or MacrosLoaded() then
        OnMacrosKnown()
    else
        C_Timer.After(15, OnMacrosKnown)
    end
    local previous = StakeoutDB.lastBuild or MEASURED_ON_BUILD
    if build ~= previous and IsDevelopmentCopy() then
        Print("Client build changed: %s -> %s (measured on %s). Check the API dump and re-measure.",
            previous, tostring(build), MEASURED_ON_BUILD)
    end
    SetConfig("lastBuild", build)
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
    if macroSyncPending then SyncMacros() end
    ApplyPendingMacroOn()
    RefreshTargetFrame()
end

-- PLAYER_REGEN_DISABLED arrives before lockdown: the last moment a drag on the
-- protected frame can still be stopped, instead of following the cursor for
-- the whole fight.
local function OnCombatStart()
    if targetFrame and targetFrame.isMoving and not InCombatLockdown() then
        targetFrame.isMoving = nil
        targetFrame:StopMovingOrSizing()
        SaveFramePosition(targetFrame)
    end
end

-- UNIT_NAME_UPDATE: a creature not yet in the client's cache shows up as
-- "Unknown" and gets its real name a moment later.
local function NameUpdated(unit)
    if IsSecret(unit) or type(unit) ~= "string" then return end
    if unit:match("^nameplate%d+$") then
        CheckUnit(unit, true)
    elseif unit == "target" or unit == "mouseover" then
        CheckUnit(unit, false)
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")

        EnsureDefaults()
        -- The look is fixed for the session before the first window is made.
        local _, why = Theme.Init(StoredLook(), StakeoutDB.followGlassUI ~= false, function()
            if not (configFrame and configFrame:IsShown()) then CreateConfigFrame() end
        end)
        if why then Print("The glass look isn't available (%s); using the WoW Forever look.", why) end
        CreateTargetFrame()

        RegisterEvents(self, "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
            "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED",
            "UPDATE_MOUSEOVER_UNIT", "UNIT_NAME_UPDATE", "UNIT_DIED", "UPDATE_MACROS")
        C_Timer.NewTicker(1, Tick)

        Rescan()

    elseif event == "PLAYER_LOGIN" then
        OnLogin()

    elseif event == "UPDATE_MACROS" then
        -- Macros may load after PLAYER_LOGIN, and an early update can arrive
        -- before they have: keep trying until our macro is found. After that
        -- this event only echoes our own writes, and a restore then could
        -- bring back a name removed in combat (its write still pending).
        if not macrosRestored then RestoreFromMacros() end
        -- Done once our macro was found, or once the macros are loaded without
        -- one (turning the mode on later adopts or creates it directly).
        if macrosRestored or MacrosLoaded() then
            self:UnregisterEvent("UPDATE_MACROS")
            OnMacrosKnown()
        end

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

    elseif event == "UNIT_NAME_UPDATE" then
        NameUpdated(...)

    elseif event == "PLAYER_REGEN_DISABLED" then
        OnCombatStart()

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
        if not RemoveWatched(rest) then Print("'%s' not found in list.", rest) end

    elseif cmd == "list" then
        if #StakeoutDB.npcList == 0 then
            Print("NPC list is empty. Use |cff00ff00/stakeout add <name>|r or open config.")
        else
            Print("Tracked NPCs (%d):", #StakeoutDB.npcList)
            for i, npc in ipairs(StakeoutDB.npcList) do
                Print("  %d. %s", i, npc)
            end
        end

    elseif cmd == "macro" then
        local arg = rest:lower()
        if arg == "on" then
            SetMacroMode(true)
        elseif arg == "off" then
            SetMacroMode(false)
        else
            Print("Keeping the list in a character macro: %s. Use |cff00ff00/stakeout macro on|r or |cff00ff00off|r.",
                macroMode and "|cff00ff00on|r" or "|cffff6666off|r")
        end

    elseif cmd == "export" then
        ShowExport()

    elseif cmd == "look" then
        local arg = rest:lower()
        if Theme.IsLook(arg) then
            ChooseLook(arg)
        else
            Print("Look: %s. Use |cff00ff00/stakeout look forever|r or |cff00ff00glass|r (applies after a /reload).",
                Theme.Following() and "Glass UI's" or Theme.LABELS[Theme.Active()])
        end

    elseif cmd == "quests" then
        -- Quests.lua owns the feature; the core only passes the command on.
        local quests = ns.quests
        if not (quests and quests.SetEnabled) then
            Print("Quest targets aren't loaded.")
            return
        end
        local arg = rest:lower()
        if arg == "on" or arg == "off" then
            quests.SetEnabled(arg == "on")
        end
        quests.PrintState()

    elseif cmd == "clear" then
        ClearWatchList()

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
        Print("  /stakeout macro on / off      — Keep the list in a character macro")
        Print("  /stakeout look forever/glass  — The windows' look (after a /reload)")
        Print("  /stakeout quests on / off     — Quest target buttons (experimental)")
        Print("  /stakeout clear               — Remove all NPCs")
        Print("  /stakeout reset               — Clear detections & rescan")
    end
end

-------------------------------------------------------------------------------
-- What Quests.lua uses from the core. It loads after this file and shares the
-- addon's namespace; the core looks ns.quests up only when it needs it.
-------------------------------------------------------------------------------
ns.core = {
    Print = Print, IsSecret = IsSecret, ReadNPC = ReadNPC, RegisterEvents = RegisterEvents,
    SetConfig = SetConfig, RequestFrameRefresh = RefreshTargetFrame, Rescan = Rescan,
    MacroSafeName = MacroSafeName, NAME_MAX = NAME_MAX, IsWatchDisplayed = IsWatchDisplayed,
    IsRefreshPending = function() return pendingRefresh end,
    SetQuestMute = SetQuestMute, PruneQuestMutes = PruneQuestMutes, LINGER = LINGER,
    BUTTON_ICONS = BUTTON_ICONS, MARKER_ICONS = MARKER_ICONS, MARKER_NAMES = MARKER_NAMES,
}

-------------------------------------------------------------------------------
-- Test seam (tests/). Harmless in game.
-------------------------------------------------------------------------------
Stakeout._test = {
    detected = detected, announced = announced, eventFailures = eventFailures,
    ReadNPC = ReadNPC, CheckUnit = CheckUnit, PlateRemoved = PlateRemoved,
    UnitDied = UnitDied, Sweep = Sweep, ParseNames = ParseNames, ExportLines = ExportLines,
    AddNames = AddNames, RefreshTargetFrame = RefreshTargetFrame, OnCombatEnd = OnCombatEnd,
    REARM = REARM, seenGUIDs = seenGUIDs,
    NAME_MAX = NAME_MAX, MACRO_NAMES = MACRO_NAMES, MACRO_EMPTY = MACRO_EMPTY, MACRO_MARK = MACRO_MARK, SetMacroMode = SetMacroMode,
    macroMode = function() return macroMode end,
    CreateConfigFrame = CreateConfigFrame, ShowExport = ShowExport,
    RegisterEvents = RegisterEvents,
    buttons = targetButtons, frame = function() return targetFrame end,
    settingsLoaded = function() return settingsLoaded end,
    LINGER = LINGER, MEASURED_ON_BUILD = MEASURED_ON_BUILD,
    Tick = Tick, MacroSafeName = MacroSafeName, ResetDetections = ResetDetections,
    lastApplied = function() return lastApplied end,
    pendingRefresh = function() return pendingRefresh end,
    look = function() return Theme.Active() end,
}
