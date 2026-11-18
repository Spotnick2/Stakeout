------------------------------------------------------------
-- test_range.lua - how far a button's NPC is, for its tooltip (#46).
--
-- Range.lua brackets a unit's distance with range checks: spells, items,
-- interactions. The stubs answer like the client NameplateDistance measured:
-- a spell says nothing once the unit is out of its range, an item the client
-- doesn't know says nothing, an interaction says yes or no. What this can't
-- judge is the client's own answers, which the in-game check settles.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local function session()
    WoW.dropEvents()
    WoW.chat = {}
    WoW.combat = false
    local T = WoW.loadAddon({ savedDB = { svLoadCheck = 1 } })
    return T, WoW.ns.range
end

-- A hunter-ish spellbook: a 30 yd attack, a 40 yd heal, a pet spell that
-- would answer for the pet (never a check), and a melee one (0-0, no check).
WoW.spellbook = {
    { id = 3044, name = "Arcane Shot", maxRange = 30, harmful = true },
    { id = 2061, name = "Flash Heal", maxRange = 40, helpful = true },
    { id = 136, name = "Mend Pet", maxRange = 45, helpful = true },
    { id = 2973, name = "Raptor Strike", maxRange = 0, harmful = true },
}
-- Items the client knows: Yeh'kinya's Bramble (10 yd), Faintly Glowing Skull
-- (40 yd), Linen Bandage (15 yd, friendly).
WoW.itemRanges = { [10699] = 10, [4945] = 40, [1251] = 15 }

local T, R = session()
check(R ~= nil, "Range.lua is loaded and sets ns.range")

WoW.SetUnit("nameplate1", { name = "Kul Tiras Sailor", guid = "Creature-0-0-0-0-3128-A1", plate = true,
                            attackable = true })
local function at(token, yards) WoW.distance[token] = yards end

------------------------------------------------------------
-- Brackets for an enemy
------------------------------------------------------------
at("nameplate1", 12)
eq(R.Text("nameplate1"), "10-28 yd", "12 yd: past the 10 yd item, inside the 28 yd interaction")
at("nameplate1", 5)
eq(R.Text("nameplate1"), "within 8 yd", "5 yd: inside the closest check")
at("nameplate1", 29)
eq(R.Text("nameplate1"), "28-30 yd", "29 yd: the spell that answered before reads its nothing only beyond its 30 yd")
at("nameplate1", 35)
eq(R.Text("nameplate1"), "30-40 yd",
    "35 yd: Arcane Shot says nothing, and it answered for this unit before: out of its 30 yd")
at("nameplate1", 55)
eq(R.Text("nameplate1"), "over 40 yd", "55 yd: past the longest check")

-- A unit no spell has answered for yet: the spell's nothing tells nothing.
WoW.SetUnit("nameplate2", { name = "Kul Tiras Marine", guid = "Creature-0-0-0-0-3129-B2", plate = true,
                            attackable = true })
at("nameplate2", 35)
eq(R.Text("nameplate2"), "28-40 yd", "a new unit at 35 yd: the spell's nothing isn't read as out of range")

eq(R.Text("nameplate3"), nil, "a unit no check can answer for: no distance")

------------------------------------------------------------
-- What isn't a check
------------------------------------------------------------
local hostile = R._test.checks().hostile
local names = {}
for _, c in ipairs(hostile) do names[#names + 1] = c.range .. ":" .. tostring(c.arg) end
eq(table.concat(names, ","), "8:3,10:10699,28:4,30:3044,40:4945",
    "enemy checks by range: interaction, item, interaction, spell, item; no melee spell, no unknown item")
local friendly = {}
for _, c in ipairs(R._test.checks().friendly) do friendly[#friendly + 1] = c.range .. ":" .. tostring(c.arg) end
eq(table.concat(friendly, ","), "8:3,15:1251,28:4,40:2061", "friendly checks: no pet spell")

------------------------------------------------------------
-- A friendly unit in combat: only the spells may be asked
------------------------------------------------------------
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-0-0-0-3142-C3" })
at("target", 20)
eq(R.Text("target"), "15-28 yd", "a friendly NPC out of combat: items and interactions too")
WoW.combat = true
eq(R.Text("target"), "within 40 yd", "in combat: the heal's 40 yd only, no item or interaction")
WoW.combat = false

------------------------------------------------------------
-- A new spell is picked up after SPELLS_CHANGED
------------------------------------------------------------
WoW.spellbook[#WoW.spellbook + 1] = { id = 75, name = "Auto Shot", maxRange = 35, minRange = 8, harmful = true }
WoW.spellbook[#WoW.spellbook + 1] = { id = 1978, name = "Serpent Sting", maxRange = 20, harmful = true }
WoW.fire("SPELLS_CHANGED")
at("nameplate1", 15)
eq(R.Text("nameplate1"), "10-20 yd", "after SPELLS_CHANGED the new 20 yd spell is a check")
local withMin = false
for _, c in ipairs(R._test.checks().hostile) do if c.arg == 75 then withMin = true end end
check(not withMin, "a spell with a minimum range (Auto Shot) is no check")

------------------------------------------------------------
-- The tooltip: the distance under the name, refreshed while it's up
------------------------------------------------------------
SlashCmdList.STAKEOUT("add Kul Tiras Sailor")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local btn = T.buttons[1]
check(btn and btn._shown, "the watched Sailor has its button")
at("nameplate1", 12)
btn._scripts.OnEnter(btn)
eq(GameTooltip._lines[1], "Kul Tiras Sailor", "the tooltip starts with the name")
eq(GameTooltip._lines[2], "Distance: 10-20 yd", "then the distance (the 20 yd sting is a check now)")

local refresher
for _, f in ipairs(WoW.frames) do
    if f._scripts.OnUpdate and f.button == btn then refresher = f end
end
check(refresher and refresher._shown, "a plain frame refreshes the tooltip while it's up")
check(not WoW.isProtected(refresher), "...never the protected button")
at("nameplate1", 35)
refresher._scripts.OnUpdate(refresher, 0.2)
eq(GameTooltip._lines[2], "Distance: 10-20 yd", "not before half a second")
refresher._scripts.OnUpdate(refresher, 0.4)
eq(GameTooltip._lines[2], "Distance: 30-40 yd", "then the new distance")
btn._scripts.OnLeave(btn)
check(not refresher._shown, "leaving the button stops the refresh")

-- A button whose NPC is no longer shown by its token: no distance line.
WoW.SetUnit("nameplate1", nil)
btn._scripts.OnEnter(btn)
for _, line in ipairs(GameTooltip._lines) do
    check(not line:find("^Distance"), "no distance for an NPC no token shows: " .. line)
end
btn._scripts.OnLeave(btn)

done("test_range")
