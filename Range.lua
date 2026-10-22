-------------------------------------------------------------------------------
-- Stakeout: how far a button's NPC is, for its tooltip (#46)
--
-- Addons can't read where another unit stands on this client (UnitPosition
-- answers only for the player and their group), so the distance is bracketed
-- with range checks, as NameplateDistance does:
--   * the player's spells that have a range (C_Spell.IsSpellInRange);
--   * items with known use ranges (C_Item.IsItemInRange);
--   * the two interaction distances (CheckInteractDistance 3 and 4).
-- The answer is a bracket such as 25-30 yd, "within 8 yd", or "over 40 yd"
-- past the longest check that answered.
--
-- What NameplateDistance measured on Forever (build 69893), relied on here:
--   * the checks answer plain values, in open-world combat too;
--   * checks on a unit you can't attack aren't allowed in combat, so in combat
--     a friendly unit gets only what the spells say;
--   * many of the listed items answer nothing on this client: an item counts
--     only once it has answered;
--   * a spell answers nothing, not false, once the unit is out of its range,
--     and nothing too when it can't apply to the unit at all. So a check that
--     has answered for a unit before reads its nothing as "out of range".
--
-- The item lists, the interaction distances and the approach come from
-- NameplateDistance 0.4.2 (Range.lua), under this licence:
--
--   MIT License
--
--   Copyright (c) 2026 Nedyar
--
--   Permission is hereby granted, free of charge, to any person obtaining a
--   copy of this software and associated documentation files (the
--   "Software"), to deal in the Software without restriction, including
--   without limitation the rights to use, copy, modify, merge, publish,
--   distribute, sublicense, and/or sell copies of the Software, and to permit
--   persons to whom the Software is furnished to do so, subject to the
--   following conditions:
--
--   The above copyright notice and this permission notice shall be included
--   in all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
--   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
--   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
--   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
--   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
--   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
--   USE OR OTHER DEALINGS IN THE SOFTWARE.
-------------------------------------------------------------------------------
local _, ns = ...

local Range = {}
ns.range = Range

local INF = math.huge
local MEMORY_MAX = 500   -- units remembered before the memory starts over

-- Items with a known use range, in yards (vanilla item data, as listed by
-- LibRangeCheck-3.0). Items the client doesn't know are skipped.
local HOSTILE_ITEMS = {
    [5] = { 8149, 22432 },          -- Voodoo Charm, Devilsaur Barb
    [10] = { 17626, 10699 },        -- Frostwolf Muzzle, Yeh'kinya's Bramble
    [20] = { 10645, 1191 },         -- Gnomish Death Ray, Bag of Marbles
    [25] = { 13289 },               -- Egan's Blaster
    [30] = { 835, 7734 },           -- Large Rope Net, Six Demon Bag
    [35] = { 18904 },               -- Zorbin's Ultra-Shrinker
    [40] = { 4945, 8348 },          -- Faintly Glowing Skull, Helm of Fire
}
local FRIENDLY_ITEMS = {
    [5] = { 8149, 1970 },           -- Voodoo Charm, Restoring Balm
    [10] = { 17626, 21267 },        -- Frostwolf Muzzle, Toasting Goblet
    [15] = { 1251, 2581 },          -- Linen Bandage, Heavy Linen Bandage
    [20] = { 21519, 12450 },        -- Mistletoe, Juju Flurry
    [25] = { 13289 },               -- Egan's Blaster
    [30] = { 1180, 954 },           -- Scroll of Stamina, Scroll of Strength
    [35] = { 18904 },               -- Zorbin's Ultra-Shrinker
    [40] = { 18662, 11562 },        -- Heavy Leather Ball, Crystal Restore
}

-- CheckInteractDistance indexes 3 and 4, in yards. Larger models reach less
-- far (LibRangeCheck-3.0's measurements).
local INTERACT = { [3] = 8, [4] = 28 }
local INTERACT_BY_RACE = {
    Tauren = { [3] = 6, [4] = 25 },
    Scourge = { [3] = 7, [4] = 27 },
}

-- Spells cast on the player's pet answer for the pet, whatever unit they are
-- asked about (NameplateDistance, measured): never checks. By name, so every
-- rank is covered.
local PET_SPELLS = { 136, 2641, 982, 1002, 6991, 19574, 755 }

-- [category] = checks sorted by range: { range, test, arg, combat }
local checks
local knownItems = {}   -- items that have answered this session
local memory, memoryCount = {}, 0   -- [guid] = { [check] = true }

local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- A check's answer: true, false, or nil when it can't tell. Never errors.
local function Ask(func, ...)
    local ok, r = pcall(func, ...)
    if not ok then return nil end
    r = Plain(r)
    if r == nil then return nil end
    return r and true or false
end

local function SpellTest(spellID, unit) return Ask(C_Spell.IsSpellInRange, spellID, unit) end

local function ItemTest(itemID, unit)
    local r = Ask(C_Item.IsItemInRange, itemID, unit)
    if r ~= nil then knownItems[itemID] = true end
    return r
end

local function InteractTest(index, unit) return Ask(CheckInteractDistance, unit, index) end

local function Add(list, range, test, arg, combat)
    list[#list + 1] = { range = range, test = test, arg = arg, combat = combat }
end

local function AddSpells()
    local pet = {}
    for _, id in ipairs(PET_SPELLS) do
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and info.name then pet[info.name] = true end
    end
    local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spell = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
    local seen = {}   -- one check per spell name and range: ranks share them
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() or 0 do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if type(info) == "table" and not info.offSpecID then
            for index = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(index, bank)
                local id = type(item) == "table" and item.itemType == spell and not item.isPassive
                    and not item.isOffSpec and item.spellID
                local s = id and C_Spell.GetSpellInfo(id)
                local maxRange = type(s) == "table" and not pet[s.name] and Plain(s.maxRange)
                -- Melee abilities say 0-0, and a minimum range (Auto Shot's 8)
                -- would need a band of its own: both are left out.
                if type(maxRange) == "number" and maxRange > 0 and (Plain(s.minRange) or 0) == 0 then
                    local range = math.floor(maxRange + 0.5)
                    for category, usable in pairs({ hostile = C_Spell.IsSpellHarmful(id),
                                                    friendly = C_Spell.IsSpellHelpful(id) }) do
                        local key = category .. range .. s.name
                        if Plain(usable) and not seen[key] then
                            seen[key] = true
                            Add(checks[category], range, SpellTest, id, true)
                        end
                    end
                end
            end
        end
    end
end

local function AddItems(list, items)
    for range, ids in pairs(items) do
        for _, id in ipairs(ids) do
            local ok, known = pcall(C_Item.GetItemInfoInstant, id)
            if ok and known then
                -- An item's range check answers only once its data is loaded.
                pcall(C_Item.RequestLoadItemDataByID, id)
                Add(list, range, ItemTest, id, false)
            end
        end
    end
end

local function ByRange(a, b) return a.range < b.range end

-- The checks, from the spellbook and the lists. Again after SPELLS_CHANGED.
function Range.Rebuild()
    checks = { hostile = {}, friendly = {}, other = {} }
    wipe(memory)
    memoryCount = 0
    pcall(AddSpells)
    AddItems(checks.hostile, HOSTILE_ITEMS)
    AddItems(checks.friendly, FRIENDLY_ITEMS)
    local ok, _, race = pcall(UnitRace, "player")
    local distances = ok and INTERACT_BY_RACE[Plain(race)] or INTERACT
    for index, range in pairs(distances) do
        for _, list in pairs(checks) do Add(list, range, InteractTest, index, false) end
    end
    for _, list in pairs(checks) do table.sort(list, ByRange) end
end

local function Category(unit)
    if Ask(UnitCanAttack, "player", unit) then return "hostile" end
    if Ask(UnitCanAssist, "player", unit) then return "friendly" end
    return "other"
end

-- The checks that have answered for this unit, by its GUID.
local function Memory(unit)
    local ok, guid = pcall(UnitGUID, unit)
    guid = ok and Plain(guid) or nil
    if type(guid) ~= "string" then return nil end
    local m = memory[guid]
    if not m then
        if memoryCount >= MEMORY_MAX then
            wipe(memory)
            memoryCount = 0
        end
        m = {}
        memory[guid] = m
        memoryCount = memoryCount + 1
    end
    return m
end

-- One check's answer for the unit, its nothing read through the memory.
local function Test(check, unit, mem)
    local r = check.test(check.arg, unit)
    if r ~= nil then
        if mem then mem[check] = true end
        return r
    end
    if mem and mem[check] then return false end
    return nil
end

-- low, high in yards (high may be math.huge), or nil when nothing answered.
function Range.Get(unit)
    if not checks then Range.Rebuild() end
    local list = checks[Category(unit)]
    local restricted = list ~= checks.hostile and InCombatLockdown()
    local mem = Memory(unit)
    local low, high, answered = 0, INF, false
    for i, check in ipairs(list) do
        if check.combat or not restricted then
            local inRange = Test(check, unit, mem)
            if inRange then
                high, answered = check.range, true
                -- The longer checks would say "in range" too. Each is asked
                -- once anyway, so that the memory can read its nothing when
                -- the unit walks out of it.
                if mem then
                    for j = i + 1, #list do
                        local later = list[j]
                        if not mem[later] and (later.combat or not restricted)
                            and (later.test ~= ItemTest or knownItems[later.arg]) then
                            Test(later, unit, mem)
                        end
                    end
                end
                break
            elseif inRange == false then
                low, answered = check.range, true
            end
        end
    end
    if not answered then return nil end
    return math.min(low, high), high
end

-- "25-30 yd", "within 8 yd", "over 40 yd", or nil when nothing could tell.
function Range.Text(unit)
    local low, high = Range.Get(unit)
    if not low then return nil end
    if high == INF then return ("over %d yd"):format(low) end
    if low == 0 then return ("within %d yd"):format(high) end
    return ("%d-%d yd"):format(low, high)
end

local events = CreateFrame("Frame")
events:RegisterEvent("SPELLS_CHANGED")
events:SetScript("OnEvent", function() checks = nil end)

Range._test = { known = knownItems, checks = function() return checks end }
