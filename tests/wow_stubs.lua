------------------------------------------------------------
-- wow_stubs.lua
--
-- The WoW: Forever surface Stakeout uses, so Stakeout.lua can load and run
-- under stock Lua 5.1 with no client. Drive it through the exported `WoW`:
--
--     dofile("tests/wow_stubs.lua")          -- FIRST, in every test file
--     WoW.SetUnit("nameplate1", { name = "Mob", guid = "Creature-1", plate = true })
--     WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
--
-- Two kinds of strictness, both on purpose:
--   * Reading a global this file doesn't define is an error. The stub is the
--     list of APIs verified present on this client (the API dump, and
--     docs/FOREVER-PROBE.md for behaviour), so it models the absences too.
--   * Widgets have no catch-all: calling a method not defined here errors.
--     Every method below was checked against the dump's widget methods
--     (SetBackdrop* come from BackdropTemplateMixin, which exists).
-- Never add something because a test failed; confirm it exists first.
------------------------------------------------------------

WoW = {}
local WoW = WoW

WoW.frames = {}         -- every frame created, in order
WoW.events = {}         -- [frame] = { [event] = true }

-- A value the client marks secret. The real thing throws when compared or
-- truth-tested; Lua 5.1 cannot model that, so tests assert the addon never
-- passes it on instead (ReadNPC must return nil for it).
WoW.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

function WoW.reset()
    WoW.time         = 1000
    WoW.inCombat     = false
    WoW.build        = "70450"
    WoW.version      = "2.1.0"   -- TOC Version: a release; "dev" is what deploy.ps1 writes
    WoW.units        = {}   -- [token] = { name, guid, dead, player, controlled, plate, secretName, secretGuid, throws }
    WoW.cvars        = { nameplateMaxDistance = "45.000000" }
    WoW.addonsLoaded = {}
    WoW.messages     = {}
    WoW.sounds       = {}   -- what was played
    WoW.refuseSound  = {}   -- [id] = true -> willPlay nil
    WoW.flashes      = 0
    WoW.timers       = {}
    WoW.badEvents    = {}   -- RegisterEvent throws
    WoW.refusedEvents = { COMBAT_LOG_EVENT_UNFILTERED = true }   -- measured: returns false
    WoW.altDown      = false
    WoW.popups       = {}
    WoW.macros       = {}   -- character macros: { name, icon, body }, index = 120 + position
    WoW.accountMacros = {}  -- account macros, index = position (1..120)
    WoW.macroSlots   = 18   -- character slots; CreateMacro fails beyond this
    WoW.playerClass  = "WARRIOR"   -- UnitClass("player")'s file name; nil: not readable yet
    WoW.distance     = {}   -- [token] = yards to that unit, for the range checks (Range.lua)
    WoW.spellbook    = {}   -- the player's spells: { id, name, maxRange, minRange, harmful, helpful }
    WoW.itemRanges   = {}   -- [itemID] = yards: the items the client knows and answers for
    -- The quest log, in log order: { questID, title, complete, rows = { QuestObjectiveInfo... },
    -- header = true for a header line }. questLogThrows: every C_QuestLog read errors.
    WoW.questLog     = {}
    WoW.questLogThrows = false
end

-- A macro as the client would hold it (for tests that start with one).
function WoW.SetMacro(name, body)
    WoW.macros[#WoW.macros + 1] = { name = name, icon = "INV_MISC_QUESTIONMARK", body = body }
end

function WoW.SetAccountMacro(name, body)
    WoW.accountMacros[#WoW.accountMacros + 1] = { name = name, icon = "INV_MISC_QUESTIONMARK", body = body }
end

-- The body of the first character macro with this name, or nil.
function WoW.macroBody(name)
    for _, m in ipairs(WoW.macros) do if m.name == name then return m.body end end
    return nil
end

-- How many character macros have this name.
function WoW.macroCount(name)
    local n = 0
    for _, m in ipairs(WoW.macros) do if m.name == name then n = n + 1 end end
    return n
end

function WoW.SetUnit(token, info)
    WoW.units[token] = info
end

function WoW.fire(event, ...)
    for frame, events in pairs(WoW.events) do
        if events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

function WoW.flushTimers()
    local list = WoW.timers
    WoW.timers = {}
    for _, t in ipairs(list) do t.fn() end
end

function WoW.advance(seconds) WoW.time = WoW.time + seconds end

function WoW.chat()
    return table.concat(WoW.messages, "\n")
end

------------------------------------------------------------
-- Widgets
------------------------------------------------------------

local Widget = {}
Widget.__index = Widget

local function newWidget(kind, name, parent, template)
    local w = setmetatable({
        kind = kind, name = name, parent = parent, template = template,
        shown = true, scripts = {}, attrs = {}, points = {}, children = {},
        scale = 1, _text = "", checked = false, value = 0, width = 100, height = 20,
        level = parent and (parent.level or 0) + 1 or 0, alpha = 1, masks = {},
    }, Widget)
    if name then _G[name] = w end
    WoW.frames[#WoW.frames + 1] = w
    -- What the templates provide that the addon reads as fields.
    if template == "UICheckButtonTemplate" then
        w.Text = newWidget("FontString")
    elseif template == "OptionsSliderTemplate" then
        w.Low, w.High, w.Text = newWidget("FontString"), newWidget("FontString"), newWidget("FontString")
    end
    return w
end

-- Protected frames refuse movement/visibility in combat, as measured.
local function isProtected(w)
    local f = w
    while f do
        if f.template == "SecureActionButtonTemplate" then return true end
        for _, child in ipairs(f.children) do
            if child.template == "SecureActionButtonTemplate" then return true end
        end
        f = nil
    end
    return false
end

local function guardProtected(w, what)
    if WoW.inCombat and isProtected(w) then
        error("ADDON_ACTION_BLOCKED: " .. what .. " on a protected frame in combat", 3)
    end
end

function Widget:SetSize(wd, h) guardProtected(self, "SetSize") self.width, self.height = wd, h end
function Widget:GetSize() return self.width, self.height end
function Widget:SetWidth(wd) self.width = wd end
function Widget:SetHeight(h) self.height = h end
function Widget:GetWidth() return self.width end
function Widget:SetPoint(...) guardProtected(self, "SetPoint") self.points[#self.points + 1] = { ... } end
function Widget:ClearAllPoints() guardProtected(self, "ClearAllPoints") self.points = {} end
function Widget:GetPoint()
    local p = self.points[#self.points] or { "CENTER", nil, "CENTER", 0, 0 }
    return p[1], p[2], p[3], p[4], p[5]
end
function Widget:SetAllPoints() end
function Widget:Show() guardProtected(self, "Show") self.shown = true end
function Widget:Hide() guardProtected(self, "Hide") self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:SetScale(s) guardProtected(self, "SetScale") self.scale = s end
function Widget:SetClampedToScreen() end
function Widget:SetMovable() end
function Widget:EnableMouse(v) self.mouse = v end
function Widget:SetFrameStrata() end
function Widget:SetToplevel(v) self.toplevel = v end
-- Raise records the order: a later raise is over an earlier one in its strata.
function Widget:Raise() WoW.raises = (WoW.raises or 0) + 1 self.raisedAt = WoW.raises end
function Widget:StartMoving() guardProtected(self, "StartMoving") self.moving = true end
function Widget:StopMovingOrSizing() guardProtected(self, "StopMovingOrSizing") self.moving = false end
function Widget:RegisterForDrag() end
function Widget:SetScript(name, fn) self.scripts[name] = fn end
function Widget:GetName() return self.name end
function Widget:IsForbidden() return false end
function Widget:SetBackdrop(b) self.backdrop = b end
function Widget:SetBackdropColor() end
function Widget:SetBackdropBorderColor() end
function Widget:CreateFontString() local c = newWidget("FontString") self.children[#self.children + 1] = c return c end
function Widget:CreateTexture(_, layer, _, sublevel)
    local c = newWidget("Texture")
    c.owner, c.layer, c.sublevel = self, layer, sublevel
    self.children[#self.children + 1] = c
    return c
end
function Widget:SetScrollChild(child) self.scrollChild = child end
-- Events: unknown names throw, refused ones return false (both measured).
function Widget:RegisterEvent(event)
    if WoW.badEvents[event] then error("unknown event " .. event) end
    if WoW.refusedEvents[event] then return false end
    WoW.events[self] = WoW.events[self] or {}
    WoW.events[self][event] = true
    return true
end
function Widget:UnregisterEvent(event)
    if WoW.events[self] then WoW.events[self][event] = nil end
end
-- Secure attributes on a protected frame in combat are blocked. Raising here
-- (rather than silently dropping the write) makes such a call fail the suite.
function Widget:SetAttribute(k, v) guardProtected(self, "SetAttribute") self.attrs[k] = v end
function Widget:GetAttribute(k) return self.attrs[k] end
function Widget:RegisterForClicks(...) guardProtected(self, "RegisterForClicks") self.clicks = { ... } end
-- Text, check buttons, sliders, edit boxes
function Widget:SetText(t) self._text = t end
function Widget:SetFontHeight(h) self.fontHeight = h end
function Widget:GetText() return self._text end
function Widget:SetFontObject() end
function Widget:SetTextColor(r, g, b, a) self.textColor = { r, g, b, a } end
function Widget:SetJustifyH() end
function Widget:SetWordWrap() end
function Widget:SetTexture(t) self.texture = t end
function Widget:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Widget:SetBlendMode() end
function Widget:SetChecked(v) self.checked = v and true or false end
function Widget:GetChecked() return self.checked end
function Widget:SetMinMaxValues() end
function Widget:SetValueStep() end
function Widget:SetObeyStepOnDrag() end
function Widget:SetValue(v)
    self.value = v
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
end
function Widget:GetValue() return self.value end
function Widget:SetAutoFocus() end
function Widget:SetMaxLetters() end
function Widget:SetTextInsets() end
function Widget:SetMultiLine() end
function Widget:ClearFocus() end
function Widget:SetFocus() end
function Widget:HighlightText() end
function Widget:SetCursorPosition() end
-- What ForeverProbe's console calls (tests/test_probe.lua loads it); each is a
-- widget method in forever-api-1.60.1.70450.md.
function Widget:SetFrameLevel(l) self.level = l end
function Widget:GetFrameStrata() return "MEDIUM" end
function Widget:GetEffectiveScale() return self.scale end
function Widget:IsVisible() return self.shown end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:SetParent(p) self.parent = p end
function Widget:SetJustifyV() end
function Widget:EnableMouseWheel() end
function Widget:GetVerticalScroll() return 0 end
function Widget:GetVerticalScrollRange() return 0 end
function Widget:SetVerticalScroll() end
function Widget:HookScript(name, fn)
    self.hooks = self.hooks or {}
    self.hooks[name] = fn
    return true
end
-- What LibGlass-1.0 calls building the glass look (Theme.lua); each is a
-- widget method in forever-api-1.60.1.70450.md (Frame:CreateMaskTexture,
-- Texture:AddMaskTexture, Texture/MaskTexture:SetTextureSliceMargins and
-- SetTextureSliceMode, Texture:SetGradient, SetHorizTile, SetVertTile,
-- SetAlpha, GetAlpha, SetVertexColor, Frame:GetFrameLevel, GetParent, GetHeight).
function Widget:GetFrameLevel() return self.level end
function Widget:GetParent() return self.parent end
function Widget:GetHeight() return self.height end
function Widget:SetAlpha(a) self.alpha = a end
function Widget:GetAlpha() return self.alpha end
function Widget:CreateMaskTexture()
    local m = newWidget("MaskTexture")
    m.owner = self
    self.children[#self.children + 1] = m
    return m
end
function Widget:AddMaskTexture(m)
    -- Measured rule (LibGlass docs/GLASS-MATERIAL.md): a mask only clips the
    -- textures of the frame that made it, so a wrong owner draws unclipped.
    assert(m.kind == "MaskTexture", "AddMaskTexture takes a mask texture")
    self.masks[#self.masks + 1] = m
end
function Widget:SetTextureSliceMargins(...) self.slice = { ... } end
function Widget:SetTextureSliceMode(mode) self.sliceMode = mode end
function Widget:SetGradient(orientation, from, to) self.gradient = { orientation, from, to } end
function Widget:SetHorizTile() end
function Widget:SetVertTile() end
function Widget:SetVertexColor() end

function CreateFrame(kind, name, parent, template)
    local w = newWidget(kind, name, parent, template)
    if parent then parent.children[#parent.children + 1] = w end
    return w
end

UIParent = newWidget("Frame", "UIParent")
GameTooltip = newWidget("GameTooltip", "GameTooltip")
function GameTooltip:SetOwner(owner) self.owner, self.lines = owner, {} end
function GameTooltip:AddLine(text) self.lines = self.lines or {} self.lines[#self.lines + 1] = text end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) WoW.messages[#WoW.messages + 1] = msg end }
UISpecialFrames = {}
StaticPopupDialogs = {}
function StaticPopup_Show(which) WoW.popups[#WoW.popups + 1] = which end
BackdropTemplateMixin = {}

function UIDropDownMenu_SetWidth() end
function UIDropDownMenu_SetText(dd, t) dd.text = t end
function UIDropDownMenu_Initialize(dd, fn) dd.initFn = fn end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info) WoW.dropdownItems[#WoW.dropdownItems + 1] = info end
WoW.dropdownItems = {}

SlashCmdList = {}

-- For LibGlass-1.0 and its LibStub: CreateColor and strmatch are in the dump,
-- and so is Enum.UITextureSliceMode (SetTextureSliceMode's argument type).
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
strmatch = string.match
Enum = { UITextureSliceMode = { Stretched = 0, Tiled = 1 } }

------------------------------------------------------------
-- Game state
------------------------------------------------------------

function GetTime() return WoW.time end
function InCombatLockdown() return WoW.inCombat end
function IsAltKeyDown() return WoW.altDown end
function GetBuildInfo() return "1.60.1", WoW.build, "Sep 22 2026", 16001, "", " " end
function FlashClientIcon() WoW.flashes = WoW.flashes + 1 end
function PlaySound(id)
    if WoW.refuseSound[id] then return nil end
    WoW.sounds[#WoW.sounds + 1] = id
    return true, 1
end
function PlaySoundFile(id)
    if WoW.refuseSound[id] then return nil end
    WoW.sounds[#WoW.sounds + 1] = id
    return true, 1
end
function SetPortraitTexture(tex, unit) tex.portrait = unit end
function issecretvalue(v) return v == WoW.SECRET end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
string.trim = strtrim

local function unit(token)
    local u = WoW.units[token]
    if u and u.throws then error("Unit data cannot be accessed while tainted") end
    return u
end
function UnitExists(token) return unit(token) ~= nil end
function UnitName(token)
    local u = unit(token)
    if not u then return nil end
    if u.secretName then return WoW.SECRET end
    return u.name, nil
end
function UnitGUID(token)
    local u = unit(token)
    if not u then return nil end
    if u.secretGuid then return WoW.SECRET end
    return u.guid
end
function UnitIsDead(token) local u = unit(token) return u and u.dead or false end
function UnitIsPlayer(token) local u = unit(token) return u and u.player or false end
function UnitPlayerControlled(token) local u = unit(token) return u and (u.player or u.controlled) or false end
function UnitClass(token)
    if token == "player" and WoW.playerClass then return "Warrior", WoW.playerClass, 1 end
    return nil
end

-- The range checks (Range.lua; dump: C_Spell, C_SpellBook, C_Item,
-- CheckInteractDistance). Modelled on NameplateDistance's measurements: a
-- spell answers nil, not false, once the unit is out of its range; an item the
-- client doesn't know (or that never answers) gives nil; an interaction answers
-- true or false. A unit with no WoW.distance gives nil to everything.
C_Spell = {}
local function bookSpell(id)
    for _, sp in ipairs(WoW.spellbook) do if sp.id == id then return sp end end
end
function C_Spell.GetSpellInfo(id)
    local sp = bookSpell(id)
    if not sp then return nil end
    return { name = sp.name, iconID = 1, originalIconID = 1, castTime = 0,
             minRange = sp.minRange or 0, maxRange = sp.maxRange or 0, spellID = id }
end
function C_Spell.IsSpellHarmful(id) local sp = bookSpell(id) return sp and sp.harmful or false end
function C_Spell.IsSpellHelpful(id) local sp = bookSpell(id) return sp and sp.helpful or false end
function C_Spell.IsSpellInRange(id, token)
    local sp, d = bookSpell(id), WoW.distance[token]
    if not (sp and d) then return nil end
    if d <= sp.maxRange then return true end
    return nil
end
C_SpellBook = {}
function C_SpellBook.GetNumSpellBookSkillLines() return 1 end
function C_SpellBook.GetSpellBookSkillLineInfo(line)
    if line ~= 1 then return nil end
    return { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = #WoW.spellbook,
             isGuild = false, shouldHide = false }
end
function C_SpellBook.GetSpellBookItemInfo(index)
    local sp = WoW.spellbook[index]
    if not sp then return nil end
    return { actionID = sp.id, spellID = sp.id, itemType = 1, name = sp.name, subName = "", iconID = 1,
             isPassive = false, isOffSpec = false }
end
C_Item = {}
function C_Item.GetItemInfoInstant(id) if WoW.itemRanges[id] then return id end end
function C_Item.RequestLoadItemDataByID() end
function C_Item.IsItemInRange(id, token)
    local r, d = WoW.itemRanges[id], WoW.distance[token]
    if not (r and d) then return nil end
    return d <= r
end
function CheckInteractDistance(token, index)
    local d = WoW.distance[token]
    if not d then return nil end
    return d <= ({ [3] = 8, [4] = 28 })[index]
end
function UnitRace(token) if token == "player" then return "Orc", "Orc", 2 end end

-- UnitCanAssist(unit, target) -> bool (dump: [Unit]): "player" and a unit
-- that isn't attackable, the stub's whole model of a friendly one.
function UnitCanAssist(token, other)
    local u = unit(other)
    if token ~= "player" or not u then return false end
    return u.attackable ~= true and u.attackable ~= WoW.SECRET
end

-- UnitCanAttack(unit, target) -> bool (dump: [Unit]). Only "player" against a
-- unit is modelled: the unit's `attackable` field.
function UnitCanAttack(token, other)
    local u = unit(other)
    if token ~= "player" or not u then return false end
    if u.attackable == WoW.SECRET then return WoW.SECRET end
    return u.attackable == true
end

------------------------------------------------------------
-- The quest log (forever-api-1.60.1.70532.md, C_QuestLog). Rows are
-- QuestObjectiveInfo { text, type, finished, numFulfilled, numRequired,
-- objectiveType }; GetInfo returns a QuestInfo (only the fields read here).
------------------------------------------------------------
C_QuestLog = {}
local function questLogGuard()
    if WoW.questLogThrows then error("quest log not available") end
end
-- WoW.questLogHidden: quests under a collapsed header. The log counts them and
-- answers for them by ID, but they aren't among the shown rows GetInfo walks.
local function questByID(questID)
    for _, list in ipairs({ WoW.questLog, WoW.questLogHidden or {} }) do
        for i, q in ipairs(list) do
            if not q.header and q.questID == questID then return q, list == WoW.questLog and i or 1000 + i end
        end
    end
end
function C_QuestLog.GetNumQuestLogEntries()
    questLogGuard()
    local quests = #(WoW.questLogHidden or {})
    for _, q in ipairs(WoW.questLog) do if not q.header then quests = quests + 1 end end
    return #WoW.questLog, quests
end
function C_QuestLog.GetLogIndexForQuestID(questID)
    questLogGuard()
    local _, index = questByID(questID)
    return index
end
function C_QuestLog.GetInfo(index)
    questLogGuard()
    local q = WoW.questLog[index]
    if not q then return nil end
    return { title = q.title or "", questLogIndex = index, questID = q.header and 0 or q.questID,
             isHeader = q.header and true or false, isHidden = false }
end
function C_QuestLog.GetQuestObjectives(questID)
    questLogGuard()
    local q = questByID(questID)
    local out = {}
    for i, r in ipairs(q and q.rows or {}) do
        out[i] = { text = r.text, type = r.type, finished = r.finished and true or false,
                   numFulfilled = r.numFulfilled or 0, numRequired = r.numRequired or 1, objectiveType = r.objectiveType }
    end
    return out
end
function C_QuestLog.IsComplete(questID)
    questLogGuard()
    local q = questByID(questID)
    return q and q.complete and true or false
end
-- UnitIsRelatedToActiveQuest(unit) -> bool. The unit's `related` field; a
-- secret one models a read that would throw when tested.
function C_QuestLog.UnitIsRelatedToActiveQuest(token)
    local u = unit(token)
    if not u then return false end
    if u.related == WoW.SECRET then return WoW.SECRET end
    return u.related == true
end

C_ClassColor = {}
function C_ClassColor.GetClassColor(class)
    if class == "WARRIOR" then return { r = 0.78, g = 0.61, b = 0.43 } end
end

------------------------------------------------------------
-- Macros. Measured on 69977 (docs/FOREVER-PROBE.md, 10): character macros
-- start at index 121, and two macros may share a name. Writes in combat are
-- modelled as blocked (a macro change is a protected action there).
------------------------------------------------------------

local MACRO_BASE = 120
local function macroCombatGuard(what)
    if WoW.inCombat then error("MACRO_ACTION_FORBIDDEN: " .. what .. " in combat", 3) end
end
local function macroAt(index)
    index = index or 0
    if index >= 1 and index <= MACRO_BASE then return WoW.accountMacros[index] end
    return WoW.macros[index - MACRO_BASE]
end
-- Returns ONE match: the first, account macros first. With duplicate names
-- that may not be the one a caller wants - which is the point.
function GetMacroIndexByName(name)
    for i, m in ipairs(WoW.accountMacros) do if m.name == name then return i end end
    for i, m in ipairs(WoW.macros) do if m.name == name then return MACRO_BASE + i end end
    return 0
end
function GetNumMacros() return #WoW.accountMacros, #WoW.macros end
function GetMacroInfo(index)
    local m = macroAt(index)
    if not m then return nil end
    return m.name, m.icon, m.body
end
function GetMacroBody(index)
    local m = macroAt(index)
    return m and m.body or nil
end
function CreateMacro(name, icon, body, perCharacter)
    macroCombatGuard("CreateMacro")
    assert(perCharacter, "Stakeout only creates character macros")
    if #WoW.macros >= WoW.macroSlots then error("Too many macros") end
    WoW.macros[#WoW.macros + 1] = { name = name, icon = icon, body = body }
    return MACRO_BASE + #WoW.macros
end
function EditMacro(index, name, icon, body)
    macroCombatGuard("EditMacro")
    local m = WoW.macros[index - MACRO_BASE]
    if not m then error("no macro at " .. tostring(index)) end
    if name then m.name = name end
    if icon then m.icon = icon end
    if body then m.body = body end
    return index
end
function DeleteMacro(index)
    macroCombatGuard("DeleteMacro")
    table.remove(WoW.macros, index - MACRO_BASE)
end

C_NamePlate = {}
function C_NamePlate.GetNamePlates()
    local plates = {}
    for token, u in pairs(WoW.units) do
        if u.plate then plates[#plates + 1] = { namePlateUnitToken = token } end
    end
    return plates
end

C_AddOns = {}
function C_AddOns.GetAddOnMetadata(name, key)
    if name == "Stakeout" and key == "Version" then return WoW.version end
    return nil
end
function C_AddOns.IsAddOnLoaded(name) return WoW.addonsLoaded[name] and true or false, WoW.addonsLoaded[name] and true or false end

C_CVar = {}
function C_CVar.GetCVar(name) return WoW.cvars[name] end
function C_CVar.SetCVar(name, value) WoW.cvars[name] = value return true end

C_Timer = {}
function C_Timer.After(seconds, fn) WoW.timers[#WoW.timers + 1] = { fn = fn, delay = seconds } end
function C_Timer.NewTicker(_, fn) local t = { fn = fn } WoW.ticker = t return t end

------------------------------------------------------------
-- Strict globals
------------------------------------------------------------

local KNOWN_ABSENT = {
    -- Gone on this client (dump + probe); the addon must not depend on them.
    CombatLogGetCurrentEventInfo = true, IsAddOnLoaded = true, MouseIsOver = true,
    GetAddOnMetadata = true, SetRaidTarget = true, TargetUnit = true,
    -- The addon's own globals, nil until it creates them / SavedVariables load.
    Stakeout = true, StakeoutDB = true,
    -- Nil until the embedded library's LibStub.lua runs (it checks for a copy).
    LibStub = true,
}

function WoW.allowGlobal(name) KNOWN_ABSENT[name] = true end

function WoW.strictGlobals()
    setmetatable(_G, {
        __index = function(_, k)
            if KNOWN_ABSENT[k] then return nil end
            error("read of undefined global '" .. tostring(k) ..
                "' - stub it (only if the dump/probe confirms it exists) or add it to " ..
                "KNOWN_ABSENT in tests/wow_stubs.lua", 2)
        end,
    })
end

-- The Lua files Stakeout.toc loads, in order.
function WoW.tocLuaFiles()
    local f = assert(io.open("Stakeout.toc", "rb"), "Stakeout.toc not found - run from the repo root")
    local files = {}
    for line in f:read("*a"):gmatch("[^\r\n]+") do
        local file = line:match("^%s*([^#%s].-%.lua)%s*$")
        if file then files[#files + 1] = (file:gsub("\\", "/")) end
    end
    f:close()
    return files
end

-- The embedded LibGlass-1.0. Libs/ is filled by the packager (.pkgmeta
-- externals) and gitignored, so the tests read the library from a checkout:
-- $LIBGLASS (CI fetches the pinned tag there), else ../LibGlass. A missing
-- checkout fails loudly: a silently skipped library would test nothing.
WoW.LIBGLASS_XML = "Libs\\LibGlass-1.0\\LibGlass-1.0.xml"

function WoW.libGlassScripts()
    local root = (os.getenv("LIBGLASS") or "../LibGlass"):gsub("\\", "/"):gsub("/$", "")
    local f = io.open(root .. "/LibGlass-1.0.xml", "rb")
    if not f then
        error("LibGlass checkout not found at " .. root .. " (no LibGlass-1.0.xml): clone "
              .. "github.com/Spotnick2/LibGlass there or set LIBGLASS", 0)
    end
    local xml = f:read("*a"):gsub("<!%-%-.-%-%->", "")   -- listed in a comment is not loaded
    f:close()
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do
        files[#files + 1] = root .. "/" .. file:gsub("\\", "/")
    end
    assert(#files > 0, "LibGlass-1.0.xml at " .. root .. " lists no Script files")
    return files
end

-- Load Stakeout the way the client does: run each file the TOC lists with
-- the addon name and one shared namespace table as `...` (the library's XML
-- runs its own scripts, each with its own), then (optionally) hand it saved
-- variables and fire ADDON_LOADED and PLAYER_LOGIN. Returns the test seam and
-- the namespace (WoW.ns too). `noLibrary` loads the addon without LibGlass.
function WoW.loadAddon(opts)
    opts = opts or {}
    local ns = opts.ns or {}
    WoW.ns = ns
    local f = assert(io.open("Stakeout.toc", "rb"))
    local toc = f:read("*a")
    f:close()
    for line in toc:gmatch("[^\r\n]+") do
        local file = line:match("^%s*([^#%s].-)%s*$")
        if file == WoW.LIBGLASS_XML then
            if not opts.noLibrary then
                for _, path in ipairs(WoW.libGlassScripts()) do assert(loadfile(path))("Stakeout", {}) end
            end
        elseif file then
            assert(file:match("%.lua$"), "the TOC loads " .. file .. ", which this loader doesn't know")
            assert(loadfile((file:gsub("\\", "/"))))("Stakeout", ns)
        end
    end
    if opts.savedDB then StakeoutDB = opts.savedDB end
    WoW.fire("ADDON_LOADED", "Stakeout")
    if opts.login ~= false then WoW.fire("PLAYER_LOGIN") end
    return Stakeout._test, ns
end

WoW.reset()
WoW.strictGlobals()
