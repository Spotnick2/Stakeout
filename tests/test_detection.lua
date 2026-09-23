------------------------------------------------------------
-- test_detection.lua - sightings, secret reads, deaths, expiry, combat.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_detection.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T = WoW.loadAddon()
local detected, announced = T.detected, T.announced

local function clean()
    for k in pairs(detected) do detected[k] = nil end
    for k in pairs(announced) do announced[k] = nil end
    WoW.units, WoW.sounds, WoW.messages, WoW.flashes, WoW.inCombat = {}, {}, {}, 0, false
    T.RefreshTargetFrame()
end

SlashCmdList.STAKEOUT("add Rare Mob; Twin Mob")

------------------------------------------------------------
-- A watched NPC on a nameplate
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
H.check(detected["Rare Mob"] ~= nil, "a watched NPC on a plate is detected")
H.eq(#WoW.sounds, 1, "one alert sound")
H.eq(WoW.flashes, 1, "one taskbar flash")
H.check(WoW.chat():find("Detected: Rare Mob", 1, true), "the chat names it")

local btn = T.buttons[1]
H.check(btn and btn.shown, "a target button is shown")
H.eq(btn:GetAttribute("type"), "macro", "left-click runs a macro")
H.eq(btn:GetAttribute("macrotext"), "/cleartarget\n/targetexact Rare Mob", "left-click targets by exact name")
H.eq(btn:GetAttribute("macrotext2"), "/cleartarget\n/targetexact Rare Mob\n/tm 6",
    "right-click targets and marks: SetRaidTarget is forbidden to addon code, the click does it")
H.eq(btn:GetAttribute("typerelease"), nil, "no typerelease: it would double-fire")
H.eq(btn.clicks and btn.clicks[1], "AnyUp", "both edges registered (the secure handler picks one)")
H.eq(btn.clicks and btn.clicks[2], "AnyDown", "both edges registered")
H.check(T.frame().shown, "the target frame is shown")

-- Seen again: no second alert
WoW.SetUnit("nameplate2", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
H.eq(#WoW.sounds, 1, "no repeat alert for the same NPC")

------------------------------------------------------------
-- Not watched, dead, a player: not sightings
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Boar", guid = "Creature-9", plate = true })
WoW.SetUnit("nameplate2", { name = "Rare Mob", guid = "Creature-1", plate = true, dead = true })
WoW.SetUnit("nameplate3", { name = "Rare Mob", guid = "Player-1", plate = true, player = true })
for i = 1, 3 do WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
H.eq(next(detected), nil, "unwatched, dead and player units are not sightings")

------------------------------------------------------------
-- Secret and unreadable units never pass through
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", secretName = true })
H.eq(T.ReadNPC("nameplate1"), nil, "a secret name reads as no name")
WoW.SetUnit("nameplate2", { name = "Rare Mob", guid = "Creature-1", throws = true })
H.eq(T.ReadNPC("nameplate2"), nil, "a read that throws is caught and reads as no name")
WoW.SetUnit("nameplate3", { name = "Rare Mob", guid = "Creature-1", secretGuid = true })
local n, g = T.ReadNPC("nameplate3")
H.eq(n, "Rare Mob", "a secret GUID still gives the (plain) name")
H.eq(g, nil, "a secret GUID is dropped, not passed on")
H.check(pcall(WoW.fire, "UNIT_DIED", WoW.SECRET), "UNIT_DIED with a secret GUID is ignored, not an error")

------------------------------------------------------------
-- Deaths by GUID: two NPCs with the same name
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Twin Mob", guid = "Creature-A", plate = true })
WoW.SetUnit("nameplate2", { name = "Twin Mob", guid = "Creature-B", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
WoW.fire("UNIT_DIED", "Creature-A")
H.check(detected["Twin Mob"] ~= nil, "one of two same-name NPCs died: the button stays")
WoW.fire("UNIT_DIED", "Creature-Z")
H.check(detected["Twin Mob"] ~= nil, "an unrelated death changes nothing")
WoW.fire("UNIT_DIED", "Creature-B")
H.eq(detected["Twin Mob"], nil, "both died: the button goes")
H.eq(announced["Twin Mob"], nil, "and a respawn alerts again")
H.check(not T.frame().shown, "the empty target frame hides")

------------------------------------------------------------
-- Leaving plate range; target and mouseover sightings linger
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.eq(detected["Rare Mob"], nil, "its plate is gone and it isn't targeted: gone at once")
H.check(announced["Rare Mob"], "walking out of range doesn't re-arm the alert")

clean()
WoW.SetUnit("mouseover", { name = "Rare Mob", guid = "Creature-1" })
WoW.fire("UPDATE_MOUSEOVER_UNIT")
H.check(detected["Rare Mob"] ~= nil, "a mouseover sighting counts")
WoW.units.mouseover = nil
WoW.advance(T.LINGER - 1)
T.Sweep()
H.check(detected["Rare Mob"] ~= nil, "it lingers for LINGER seconds")
WoW.advance(2)
T.Sweep()
H.eq(detected["Rare Mob"], nil, "then expires")

clean()
WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
WoW.advance(T.LINGER * 3)
T.Sweep()
H.check(detected["Rare Mob"] ~= nil, "still targeted: it stays however long")

-- Plate gone but still targeted
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.check(detected["Rare Mob"] ~= nil, "plate gone but still the target: it stays")

-- The other order (PR #9 review, P1): targeted first, then its plate shows
-- and leaves. The later plate sighting must not make the target forgotten.
clean()
WoW.SetUnit("target", { name = "Rare Mob", guid = "Creature-1" })
WoW.fire("PLAYER_TARGET_CHANGED")
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
H.check(detected["Rare Mob"] ~= nil, "targeted, then plate came and went: it stays while targeted")
WoW.units.target = nil
WoW.advance(T.LINGER + 1)
T.Sweep()
H.eq(detected["Rare Mob"], nil, "and goes once it is neither targeted nor recent")

-- Same-name NPCs without plates (PR #9 review, P2): target A, mouseover B.
clean()
WoW.SetUnit("target", { name = "Twin Mob", guid = "Creature-A" })
WoW.fire("PLAYER_TARGET_CHANGED")
WoW.SetUnit("mouseover", { name = "Twin Mob", guid = "Creature-B" })
WoW.fire("UPDATE_MOUSEOVER_UNIT")
WoW.units.target.dead = true
WoW.fire("UNIT_DIED", "Creature-A")
H.check(detected["Twin Mob"] ~= nil, "A died; B (seen on mouseover) keeps the button")
T.Sweep()
H.check(detected["Twin Mob"] ~= nil, "the mouseover still shows B: it stays")
WoW.units.mouseover.dead = true
WoW.fire("UNIT_DIED", "Creature-B")
H.eq(detected["Twin Mob"], nil, "both died: gone")

-- Same-name pair: A walks out of range (no death), B dies (PR #9 follow-up).
-- A's GUID keeps the entry until it expires; the alert must re-arm then.
clean()
WoW.SetUnit("nameplate1", { name = "Twin Mob", guid = "Creature-A", plate = true })
WoW.SetUnit("nameplate2", { name = "Twin Mob", guid = "Creature-B", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
WoW.units.nameplate1 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
WoW.units.nameplate2 = nil
WoW.fire("UNIT_DIED", "Creature-B")
WoW.advance(T.LINGER + 1)
T.Sweep()
H.eq(detected["Twin Mob"], nil, "the entry expires once nothing shows it")
H.eq(announced["Twin Mob"], nil, "and a death on the way out re-arms the alert")

------------------------------------------------------------
-- Combat: detect and alert, but never touch the protected frame
------------------------------------------------------------
clean()
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")      -- creates the secure button out of combat
clean()
WoW.inCombat = true
WoW.SetUnit("nameplate1", { name = "Twin Mob", guid = "Creature-A", plate = true })
local ok, err = pcall(WoW.fire, "NAME_PLATE_UNIT_ADDED", "nameplate1")
H.check(ok, "a sighting in combat doesn't touch the protected frame (" .. tostring(err) .. ")")
H.check(detected["Twin Mob"] ~= nil, "it is still recorded in combat")
H.eq(#WoW.sounds, 1, "and still alerts in combat")
ok, err = pcall(WoW.fire, "UNIT_DIED", "Creature-A")
H.check(ok, "a death in combat doesn't touch the protected frame (" .. tostring(err) .. ")")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
WoW.inCombat = false
WoW.fire("PLAYER_REGEN_ENABLED")
H.eq(T.buttons[1]:GetAttribute("macrotext"), "/cleartarget\n/targetexact Twin Mob",
    "the buttons are rebuilt when combat ends")

------------------------------------------------------------
-- Marking off: no right-click action
------------------------------------------------------------
clean()
StakeoutDB.enableMarking = false
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
H.eq(T.buttons[1]:GetAttribute("type2"), nil, "marking off: right-click does nothing")
H.eq(T.buttons[1]:GetAttribute("macrotext2"), nil, "marking off: no mark macro")
StakeoutDB.enableMarking = true

H.done("test_detection")
