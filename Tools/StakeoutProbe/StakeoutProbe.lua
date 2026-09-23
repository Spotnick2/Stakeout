-- ============================================================================
-- StakeoutProbe  -  throwaway API probe for the WoW: Forever 1.60.1 port (#2).
--
-- Deploy with `pwsh Tools/deploy.ps1 -Probe`. Every probe prints to chat and
-- appends to a log; `/soprobe text` opens it in a copyable window, and /reload
-- also writes it to WTF\Account\<id>\SavedVariables\StakeoutProbe.lua.
--
-- Nothing here ships. Delete Tools/StakeoutProbe once docs/FOREVER-PROBE.md
-- is settled.
-- ============================================================================

local C = "|cffff8800[SOProbe]|r "

-- SavedVariables sentinel: capture what arrived BEFORE touching anything.
-- Only a count that grows across FULL client exits proves loading works.
local SV_ACCOUNT_BEFORE = StakeoutProbeDB and StakeoutProbeDB.launches or 0
local SV_CHAR_BEFORE    = StakeoutProbeChar and StakeoutProbeChar.launches or 0

StakeoutProbeDB = { launches = SV_ACCOUNT_BEFORE + 1, lines = {} }
StakeoutProbeChar = { launches = SV_CHAR_BEFORE + 1 }

local MACRO_NAME = "SOProbe"

-- ─── formatting ──────────────────────────────────────────────────────────────

local function isSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) or false
end

local function fmt(v, depth)
    if isSecret(v) then return "<SECRET " .. type(v) .. ">" end
    depth = depth or 0
    local t = type(v)
    if t == "string" then return '"' .. v .. '"' end
    if t ~= "table" then return tostring(v) end
    if depth > 1 then return "<table>" end
    local parts = {}
    for k, val in pairs(v) do
        local ok, s = pcall(fmt, val, depth + 1)
        parts[#parts + 1] = tostring(k) .. "=" .. (ok and s or "<err>")
        if #parts >= 24 then parts[#parts + 1] = "..." break end
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function pack(...) return { n = select("#", ...), ... } end

-- Call fn, never throw. Returns a printable string of everything it returned,
-- trailing nils included (a declared-optional return is part of the answer).
local function try(fn, ...)
    if type(fn) ~= "function" then return "API MISSING" end
    local packed = pack(pcall(fn, ...))
    if not packed[1] then return "ERROR: " .. tostring(packed[2]) end
    if packed.n <= 1 then return "<no return>" end
    local parts = {}
    for i = 2, packed.n do
        local ok, s = pcall(fmt, packed[i])
        parts[#parts + 1] = ok and s or "<unprintable>"
    end
    return table.concat(parts, ", ")
end

local function say(msg) DEFAULT_CHAT_FRAME:AddMessage(C .. msg) end

local section = "?"
local function head(name)
    section = name
    local lines = StakeoutProbeDB.lines
    lines[#lines + 1] = " "
    lines[#lines + 1] = "== " .. name .. "  [" .. date("%H:%M:%S") ..
        (InCombatLockdown() and ", IN COMBAT" or "") .. "] =="
    say("|cff99ddff== " .. name .. " ==|r")
end

local function rec(key, value)
    local line = string.format("%-44s %s", section .. "." .. tostring(key), tostring(value))
    local lines = StakeoutProbeDB.lines
    lines[#lines + 1] = line
    say(line)
end

local P = {}

-- ─── client: templates, CVar, popups, combat log, macro limits ───────────────

local TEMPLATES = {
    { "Frame",       "BackdropTemplate" },
    { "Frame",       "UIDropDownMenuTemplate" },
    { "Slider",      "OptionsSliderTemplate" },
    { "Slider",      "MinimalSliderWithSteppersTemplate" },
    { "CheckButton", "UICheckButtonTemplate" },
    { "ScrollFrame", "UIPanelScrollFrameTemplate" },
    { "Button",      "UIPanelButtonTemplate" },
    { "Button",      "UIPanelCloseButton" },
    { "DropdownButton", "WowStyle1DropdownTemplate" },
    { "Button",      "SecureActionButtonTemplate" },
}

function P.client()
    head("client")
    rec("GetBuildInfo", try(GetBuildInfo))
    rec("ActionButtonUseKeyDown", try(C_CVar.GetCVar, "ActionButtonUseKeyDown"))

    head("templates")
    for i, t in ipairs(TEMPLATES) do
        -- Named, so a template that needs $parent-style children resolves.
        local ok, frame = pcall(CreateFrame, t[1], "StakeoutProbeTpl" .. i, UIParent, t[2])
        if ok and frame then frame:Hide() end
        rec(t[2], ok and "ok" or ("FAILED: " .. tostring(frame)))
    end
    rec("UIDropDownMenu_Initialize", type(UIDropDownMenu_Initialize))
    rec("MenuUtil", type(MenuUtil))

    head("nameplateMaxDistance")
    local cvar = "nameplateMaxDistance"
    local original = C_CVar.GetCVar(cvar)
    rec("GetCVarInfo", try(C_CVar.GetCVarInfo, cvar))
    for _, v in ipairs({ "41", "60", "100" }) do
        local ok, res = pcall(C_CVar.SetCVar, cvar, v)
        rec("set " .. v, (ok and tostring(res) or ("ERROR " .. tostring(res))) ..
            " -> reads back " .. tostring(C_CVar.GetCVar(cvar)))
    end
    if original then C_CVar.SetCVar(cvar, original) end
    rec("restored", tostring(C_CVar.GetCVar(cvar)))

    head("popups")
    for i = 1, 4 do
        local f = _G["StaticPopup" .. i]
        rec("StaticPopup" .. i, f and string.format("exists text=%s Text=%s",
            tostring(f.text ~= nil), tostring(f.Text ~= nil)) or "nil")
    end
    rec("StaticPopup_FindVisible", type(StaticPopup_FindVisible))
    rec("StaticPopupDialogs.ADDON_ACTION_FORBIDDEN",
        StaticPopupDialogs and StaticPopupDialogs.ADDON_ACTION_FORBIDDEN and "defined" or "nil")
    rec("UIParent handles ADDON_ACTION_FORBIDDEN",
        try(UIParent.IsEventRegistered, UIParent, "ADDON_ACTION_FORBIDDEN"))
    rec("ADDON_ACTION_FORBIDDEN (text)", tostring(ADDON_ACTION_FORBIDDEN))

    head("combatlog")
    rec("CombatLogGetCurrentEventInfo", type(CombatLogGetCurrentEventInfo))
    rec("C_CombatLog.IsCombatLogRestricted", try(C_CombatLog and C_CombatLog.IsCombatLogRestricted))
    rec("C_CombatLogInternal.GetCurrentEventInfo (idle)",
        try(C_CombatLogInternal and C_CombatLogInternal.GetCurrentEventInfo))
    rec("C_CombatLogSecure.GetCurrentEventInfo (idle)",
        try(C_CombatLogSecure and C_CombatLogSecure.GetCurrentEventInfo))

    head("macros")
    rec("GetNumMacros (account, character)", try(GetNumMacros))
    rec("MAX_ACCOUNT_MACROS", tostring(MAX_ACCOUNT_MACROS))
    rec("MAX_CHARACTER_MACROS", tostring(MAX_CHARACTER_MACROS))
    rec("index of " .. MACRO_NAME, try(GetMacroIndexByName, MACRO_NAME))
end

-- ─── sounds: willPlay for every entry Stakeout offers ────────────────────────

local SOUNDS = {
    { "Raid Warning", SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959 },
    { "Ready Check", SOUNDKIT and SOUNDKIT.READY_CHECK or 8960 },
    { "Whisper", SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081 },
    { "Murloc Aggro", SOUNDKIT and SOUNDKIT.MURLOC_AGGRO or 416 },
    { "Alarm Clock", SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3 or 12889 },
    { "Loatheb: I See You", 8826 },
    { "Horn of Awakening", 7034 }, { "Horn of Cenarius", 10843 }, { "Horn: Dwarf", 10966 },
    { "Foghorn", 11630 }, { "Boat Warning", 10170 },
    { "PvP Warning: Alliance", 8455 }, { "PvP Warning: Horde", 8456 }, { "PvP: Flag Taken", 8457 },
    { "PvP: Enter Queue", SOUNDKIT and SOUNDKIT.PVP_ENTER_QUEUE or 8458 },
    { "PvP: Through Queue", SOUNDKIT and SOUNDKIT.PVP_THROUGH_QUEUE or 8459 },
    { "Bell: Dwarf/Gnome", 7234 },
    { "Bell: Alliance", "Sound\\Doodad\\BellTollAlliance.ogg" },
    { "Bell: Horde", "Sound\\Doodad\\BellTollHorde.ogg" },
    { "Bell: Night Elf", "Sound\\Doodad\\BellTollNightElf.ogg" },
    { "Bell: Karazhan", "Sound\\Doodad\\KharazahnBellToll.ogg" },
    { "Ogre War Drums", "Sound\\Event Sounds\\Event_wardrum_ogre.ogg" },
    { "Troll Drums", "Sound\\Doodad\\TrollDrumLoop1.ogg" },
    { "Fireworks", "Sound\\Doodad\\G_FireworkLauncher02Custom0.ogg" },
    { "Goblin Spring", "Sound\\Doodad\\Goblin_Lottery_Open03.ogg" },
    { "Gnome Yell", "Sound\\Character\\Gnome\\GnomeVocalFemale\\GnomeFemalePissed01.ogg" },
}

function P.sounds()
    head("sounds")
    local i = 0
    -- Spaced out so each result can be heard, and stopped so they do not pile up.
    C_Timer.NewTicker(1.2, function()
        i = i + 1
        local s = SOUNDS[i]
        if not s then return end
        section = "sounds"
        local id = s[2]
        local how, ok, willPlay, handle
        if type(id) == "number" then
            how = "PlaySound"
            ok, willPlay, handle = pcall(PlaySound, id, "Master")
            if ok and not willPlay then
                how = "PlaySound->PlaySoundFile"
                ok, willPlay, handle = pcall(PlaySoundFile, id, "Master")
            end
        else
            how = "PlaySoundFile"
            ok, willPlay, handle = pcall(PlaySoundFile, id, "Master")
        end
        rec(s[1], how .. " " .. (ok and (willPlay and "PLAYS" or "refused") or ("ERROR " .. tostring(willPlay))))
        if handle then C_Timer.After(1.0, function() StopSound(handle) end) end
    end, #SOUNDS)
end

-- ─── unit reads: secrecy of names and GUIDs ──────────────────────────────────

local function readUnit(label, unit)
    if not UnitExists(unit) then return end
    local okN, name = pcall(UnitName, unit)
    local okG, guid = pcall(UnitGUID, unit)
    local cmp = "n/a"
    if okN then
        local okC, eq = pcall(function() return name == "x" end)
        cmp = okC and "compare ok" or ("compare THROWS: " .. tostring(eq))
    end
    rec(label, string.format("name=%s guid=%s secretIdentity=%s dead=%s %s",
        okN and fmt(name) or ("ERROR " .. tostring(name)),
        okG and fmt(guid) or ("ERROR " .. tostring(guid)),
        try(C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret, unit),
        try(UnitIsDead, unit), cmp))
end

function P.unit()
    head("unit")
    rec("HasSecretRestrictions", try(C_Secrets and C_Secrets.HasSecretRestrictions))
    readUnit("target", "target")
    readUnit("mouseover", "mouseover")
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local token = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if token then readUnit(token, token) end
    end
end

-- ─── TargetUnit proximity trick ──────────────────────────────────────────────

local probeTargetName     -- set only for the duration of the TargetUnit call
local forbiddenDuringCall

local function targetName()
    local ok, n = pcall(UnitName, "target")
    return ok and fmt(n) or "<err>"
end

function P.target(arg)
    if arg == "" then say("usage: /soprobe target <exact NPC name>") return end
    head("target " .. arg)
    local before = targetName()
    forbiddenDuringCall = nil
    probeTargetName = arg
    local ok, err = pcall(TargetUnit, arg, true)
    probeTargetName = nil
    rec("call", ok and "returned" or ("ERROR " .. tostring(err)))
    rec("forbidden fired DURING the call", tostring(forbiddenDuringCall or false))
    rec("target before -> after", before .. " -> " .. targetName())
    C_Timer.After(0.5, function()
        section = "target " .. arg
        local which = StaticPopup_FindVisible and StaticPopup_FindVisible("ADDON_ACTION_FORBIDDEN")
        rec("popup visible 0.5s later", which and (which:GetName() or "anonymous") or "no")
    end)
end

-- ─── event watch: plates, deaths, forbidden/blocked, combat log ──────────────

local watch = CreateFrame("Frame")
local plateGUIDs = {}   -- guid -> "name (token)" seen on a plate
local cleuSamples = 0

local WATCH_EVENTS = {
    "NAME_PLATE_UNIT_ADDED", "UNIT_DIED", "ADDON_ACTION_BLOCKED",
    "MACRO_ACTION_FORBIDDEN", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "COMBAT_LOG_EVENT_UNFILTERED",
}

-- ADDON_ACTION_FORBIDDEN is always watched: the target probe depends on it.
watch:RegisterEvent("ADDON_ACTION_FORBIDDEN")

watch:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_ACTION_FORBIDDEN" then
        if probeTargetName then forbiddenDuringCall = true end
        local packed = { ... }
        section = "event"
        rec("ADDON_ACTION_FORBIDDEN", fmt(packed) .. (probeTargetName and " (during TargetUnit)" or ""))
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local token = ...
        local okN, name = pcall(UnitName, token)
        local okG, guid = pcall(UnitGUID, token)
        if okG and guid and not isSecret(guid) then
            plateGUIDs[guid] = (okN and fmt(name) or "?") .. " (" .. token .. ")"
        end
        section = "event"
        rec("plate+ " .. token, "name=" .. (okN and fmt(name) or "ERR") ..
            " guid=" .. (okG and fmt(guid) or "ERR") .. (InCombatLockdown() and " IN COMBAT" or ""))
    elseif event == "UNIT_DIED" then
        local guid = ...
        section = "event"
        rec("UNIT_DIED", fmt(guid) .. " -> plate match: " ..
            tostring(not isSecret(guid) and plateGUIDs[guid] or "none"))
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if cleuSamples >= 5 then return end
        cleuSamples = cleuSamples + 1
        section = "event"
        rec("CLEU Internal", try(C_CombatLogInternal and C_CombatLogInternal.GetCurrentEventInfo))
        rec("CLEU Secure", try(C_CombatLogSecure and C_CombatLogSecure.GetCurrentEventInfo))
    else
        section = "event"
        rec(event, fmt({ ... }))
    end
end)

function P.watch()
    head("watch")
    watch.on = not watch.on
    for _, ev in ipairs(WATCH_EVENTS) do
        if watch.on then
            local ok, res = pcall(watch.RegisterEvent, watch, ev)
            rec("register " .. ev, ok and tostring(res) or ("THROWS: " .. tostring(res)))
        else
            pcall(watch.UnregisterEvent, watch, ev)
        end
    end
    cleuSamples = 0
    rec("watch", watch.on and "ON - pull and kill watched NPCs, then /soprobe watch again" or "OFF")
end

-- ─── popup: toggle UIParent's handling of ADDON_ACTION_FORBIDDEN ─────────────

function P.popup()
    head("popup")
    if UIParent:IsEventRegistered("ADDON_ACTION_FORBIDDEN") then
        UIParent:UnregisterEvent("ADDON_ACTION_FORBIDDEN")
        rec("UIParent", "UNREGISTERED - re-run the target probe to see if the popup is gone")
    else
        UIParent:RegisterEvent("ADDON_ACTION_FORBIDDEN")
        rec("UIParent", "registered again")
    end
end

-- ─── secure macro button: /targetexact on both edges, and a combat drag ──────

local host
function P.button(arg)
    if arg == "" then say("usage: /soprobe button <exact NPC name>") return end
    if InCombatLockdown() then say("out of combat, please") return end
    head("button " .. arg)
    if not host then
        host = CreateFrame("Frame", "StakeoutProbeHost", UIParent, "BackdropTemplate")
        host:SetSize(80, 60)
        host:SetPoint("CENTER", 0, 150)
        host:SetMovable(true)
        host:EnableMouse(true)
        host:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
        host:SetBackdropColor(0.3, 0.1, 0, 0.8)
        -- Deliberately unguarded, like Stakeout's frame today: drag it in combat.
        host:SetScript("OnMouseDown", function(self)
            local ok, err = pcall(self.StartMoving, self)
            section = "button"
            rec("StartMoving" .. (InCombatLockdown() and " IN COMBAT" or ""), ok and "ok" or tostring(err))
        end)
        host:SetScript("OnMouseUp", function(self) pcall(self.StopMovingOrSizing, self) end)

        local b = CreateFrame("Button", "StakeoutProbeTargetBtn", host, "SecureActionButtonTemplate")
        b:SetSize(32, 32)
        b:SetPoint("BOTTOM", 0, 6)
        local tex = b:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(135274)
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type", "macro")
        b:SetScript("PostClick", function(_, mouse, down)
            C_Timer.After(0.2, function()
                section = "button"
                rec("click " .. tostring(mouse) .. (down and " down" or " up") ..
                    (InCombatLockdown() and " IN COMBAT" or ""), "target now " .. targetName())
            end)
        end)
        host.btn = b
    end
    host.btn:SetAttribute("macrotext", "/cleartarget\n/targetexact " .. arg)
    host:Show()
    rec("button", "shown - click it (left and right), in and out of combat; drag the brown box in combat")
end

-- ─── raid marker ─────────────────────────────────────────────────────────────

function P.mark()
    head("mark")
    readUnit("target", "target")
    rec("SetRaidTarget(target, 6)", try(SetRaidTarget, "target", 6))
    C_Timer.After(0.3, function() rec("GetRaidTargetIndex", try(GetRaidTargetIndex, "target")) end)
end

-- ─── macros: can a character macro carry the watch list across restarts? ─────

local function macroState()
    local idx = GetMacroIndexByName(MACRO_NAME)
    if not idx or idx == 0 then return "absent" end
    local body = GetMacroBody(idx) or ""
    return string.format("index=%d len=%d body=%q", idx, #body, body)
end

function P.macro(arg)
    head("macro " .. arg)
    rec("GetNumMacros (account, character)", try(GetNumMacros))
    local stamp = date("%Y-%m-%d %H:%M:%S")
    if arg == "create" then
        -- perCharacter = true; the index returned tells which bank it landed in
        -- (character macros start after MAX_ACCOUNT_MACROS).
        rec("CreateMacro", try(CreateMacro, MACRO_NAME, "INV_MISC_QUESTIONMARK",
            "/stakeout add Created " .. stamp, true))
        rec("CreateMacro again (collision)", try(CreateMacro, MACRO_NAME, "INV_MISC_QUESTIONMARK",
            "/stakeout add Duplicate " .. stamp, true))
    elseif arg == "edit" then
        local idx = GetMacroIndexByName(MACRO_NAME)
        rec("EditMacro", try(EditMacro, idx, nil, nil, "/stakeout add Edited " .. stamp))
    elseif arg == "big" then
        local idx = GetMacroIndexByName(MACRO_NAME)
        for _, n in ipairs({ 255, 256 }) do
            local body = ("/stakeout add Big " .. stamp .. " "):sub(1, n)
            body = body .. string.rep("x", n - #body)
            rec("EditMacro " .. n .. " chars", try(EditMacro, idx, nil, nil, body))
            rec("stored length", #(GetMacroBody(idx) or ""))
        end
    elseif arg == "delete" then
        rec("DeleteMacro", try(DeleteMacro, MACRO_NAME))
    elseif arg ~= "" and arg ~= "check" then
        say("usage: /soprobe macro create|edit|big|check|delete  (also try create/edit IN COMBAT)")
        return
    end
    rec("state", macroState())
end

-- ─── sv: SavedVariables sentinel ─────────────────────────────────────────────

function P.sv()
    head("sv")
    rec("launches before this session (account, character)", SV_ACCOUNT_BEFORE .. ", " .. SV_CHAR_BEFORE)
    rec("meaning", (SV_ACCOUNT_BEFORE == 0 and SV_CHAR_BEFORE == 0)
        and "nothing loaded back (a real failure unless this is the very first run)"
        or "a value came back - only meaningful after a FULL client exit")
end

-- ─── copy window ─────────────────────────────────────────────────────────────

local function ShowCopyWindow()
    local f = StakeoutProbeCopyFrame
    if not f then
        f = CreateFrame("Frame", "StakeoutProbeCopyFrame", UIParent, "BackdropTemplate")
        f:SetSize(760, 520)
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
        title:SetText("Stakeout Probe  -  click inside, Ctrl+A, Ctrl+C")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        local scroll = CreateFrame("ScrollFrame", "StakeoutProbeCopyScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -34)
        scroll:SetPoint("BOTTOMRIGHT", -34, 14)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject("ChatFontNormal")
        eb:SetWidth(690)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() f:Hide() end)
        scroll:SetScrollChild(eb)
        f.eb = eb
    end
    f.eb:SetText(table.concat(StakeoutProbeDB.lines, "\n"))
    f.eb:SetCursorPosition(0)
    f:Show()
    f.eb:SetFocus()
    f.eb:HighlightText()
end

-- ─── driver ──────────────────────────────────────────────────────────────────

local USAGE = "client | sounds | unit | watch | popup | target <name> | button <name> | mark | " ..
    "macro create|edit|big|check|delete | sv | text"

SLASH_SOPROBE1 = "/soprobe"
SlashCmdList["SOPROBE"] = function(msg)
    local cmd, arg = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "text" or cmd == "copy" then
        ShowCopyWindow()
    elseif P[cmd] then
        local ok, err = pcall(P[cmd], arg or "")
        if not ok then say("|cffff4444" .. cmd .. " ERRORED: " .. tostring(err) .. "|r") end
    else
        say("usage: /soprobe " .. USAGE)
    end
end

-- At login, and again once macros have loaded, report what came back: the
-- macro body and the SV counters are the two persistence answers (#2 items 10-11).
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("UPDATE_MACROS")
boot:SetScript("OnEvent", function(self, event)
    head("login (" .. event .. ")")
    rec("macro", macroState())
    rec("SV launches before (account, character)", SV_ACCOUNT_BEFORE .. ", " .. SV_CHAR_BEFORE)
    if event == "UPDATE_MACROS" then self:UnregisterEvent("UPDATE_MACROS") end
end)
