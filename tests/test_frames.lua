------------------------------------------------------------
-- test_frames.lua - execute every script handler Stakeout installs.
--
-- Strict globals and the method-strict widgets only catch code that runs, and
-- a handler nothing calls is exactly where a removed API hides. So this file
-- builds every frame, then fires every script on every one of them, and the
-- dropdown's items, and the clear-all confirmation - out of combat and in it.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T = WoW.loadAddon()
SlashCmdList.STAKEOUT("add Rare Mob; Other Mob")
WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-1", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
SlashCmdList.STAKEOUT("config")
SlashCmdList.STAKEOUT("export")

local ARGS = {
    OnClick = { "LeftButton", false }, OnMouseDown = { "LeftButton" }, OnMouseUp = { "LeftButton" },
    OnValueChanged = { 150 },
}
local SKIP = { OnEvent = true }   -- driven through WoW.fire elsewhere

local function fireAll(label)
    local frames = {}
    for i, f in ipairs(WoW.frames) do frames[i] = f end   -- handlers create frames
    local ran = 0
    for _, f in ipairs(frames) do
        for script, fn in pairs(f._scripts) do
            if not SKIP[script] then
                local args = ARGS[script] or {}
                local ok, err = pcall(fn, f, args[1], args[2])
                check(ok, label .. ": " .. tostring(f._name or f._type) .. " " .. script .. " - " .. tostring(err))
                ran = ran + 1
            end
        end
    end
    return ran
end

local ran = fireAll("out of combat")
check(ran > 40, "handlers were actually executed (" .. ran .. ")")

-- The sound dropdown's items, each previewing its sound.
local dd = StakeoutSoundDropdown
WoW.dropdownItems = {}
dd.initFn()
eq(#WoW.dropdownItems, 26, "26 sounds without DBM-Core: 17 built-in, 9 from NodeRadar")
for _, info in ipairs(WoW.dropdownItems) do
    check(pcall(info.func), "dropdown item " .. tostring(info.text))
end
WoW.addonsLoaded["DBM-Core"] = true
WoW.dropdownItems = {}
dd.initFn()
eq(#WoW.dropdownItems, 33, "plus 7 with DBM-Core")

-- NodeRadar's nine: each through the call that plays it (a FileDataID or a
-- path through PlaySoundFile only; the minimap ping is a SoundKit), and each
-- preview says it's set, not the Raid Warning fallback.
local MEDIA = "Interface\\AddOns\\Stakeout\\Media\\"
local nodeRadar = {
    ["Minimap Ping"] = "PlaySound 3175",
    ["Sonar Ping"] = "PlaySoundFile 569006",
    ["Radar Ping"] = "PlaySoundFile 7466154",
    ["Sonar"] = "PlaySoundFile " .. MEDIA .. "Sonar.ogg",
    ["Radar Blip"] = "PlaySoundFile " .. MEDIA .. "RadarBlip.ogg",
    ["Deep Sea Sonar"] = "PlaySoundFile " .. MEDIA .. "DeepSea.ogg",
    ["Bell Chime"] = "PlaySoundFile " .. MEDIA .. "BellChime.ogg",
    ["Notification"] = "PlaySoundFile " .. MEDIA .. "Notification.ogg",
    ["HUD Ping"] = "PlaySoundFile " .. MEDIA .. "HudPing.ogg",
}
local found = 0
for _, info in ipairs(WoW.dropdownItems) do
    local want = nodeRadar[info.text]
    if want then
        found = found + 1
        WoW.soundCalls, WoW.chat = {}, {}
        info.func()
        eq(table.concat(WoW.soundCalls, ", "), want, info.text .. ": plays through " .. want:match("^%S+"))
        check(WoW.chatText():find("Alert sound set to: " .. info.text, 1, true), "...and its preview says it's set")
    end
end
eq(found, 9, "all nine are offered")
for _, f in ipairs({ "Sonar", "RadarBlip", "DeepSea", "BellChime", "Notification", "HudPing" }) do
    local h = io.open("Media/" .. f .. ".ogg", "rb")
    check(h ~= nil, "Media/" .. f .. ".ogg is in the repo")
    if h then h:close() end
end

-- A refused sound falls back to Raid Warning.
WoW.sounds = {}
WoW.refuseSound[8826] = true
StakeoutDB.soundChoice = "Loatheb: I See You"
SlashCmdList.STAKEOUT("add Other Mob")   -- fireAll clicked every row's delete button
WoW.SetUnit("nameplate2", { name = "Other Mob", guid = "Creature-2", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
eq(WoW.sounds[#WoW.sounds], 8959, "a refused alert sound falls back to Raid Warning")

-- Clear-all confirmation
check(StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM ~= nil, "Clear All asks first")
check(pcall(StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM.OnAccept), "confirming Clear All runs")
eq(#StakeoutDB.npcList, 0, "and clears the list")

-- The watch list column: its count, and the empty state while nothing is watched (#34).
eq(StakeoutConfigFrame.countLabel:GetText(), "0 tracked", "the count says none")
check(StakeoutConfigFrame.emptyTitle:IsShown() and StakeoutConfigFrame.emptyHint:IsShown(),
    "an empty list says so")
eq(StakeoutConfigFrame.emptyTitle:GetText(), "No NPCs tracked", "in the empty state's words")
SlashCmdList.STAKEOUT("add Other Mob; Rare Mob")
eq(StakeoutConfigFrame.countLabel:GetText(), "2 tracked", "the count follows the list")
check(not StakeoutConfigFrame.emptyTitle:IsShown() and not StakeoutConfigFrame.emptyHint:IsShown(),
    "and the empty state goes once something is watched")
StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM.OnAccept()
check(StakeoutConfigFrame.emptyTitle:IsShown(), "and comes back when the list is cleared")
eq(#StakeoutDB.npcList, 0, "which leaves the list empty for what follows")

------------------------------------------------------------
-- In combat: the protected target frame must not be touched
------------------------------------------------------------
SlashCmdList.STAKEOUT("add Rare Mob")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local frame = T.frame()
WoW.combat = true
check(pcall(frame._scripts.OnMouseDown, frame, "LeftButton"), "a drag attempt in combat is ignored")
check(not frame._moving, "and doesn't start moving")
fireAll("in combat")
for _, event in ipairs({ "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_DIED" }) do
    check(pcall(WoW.fire, event, "nameplate1"), event .. " in combat")
end
WoW.combat = false
check(pcall(WoW.fire, "PLAYER_REGEN_ENABLED"), "combat end")

-- A drag held as combat starts is stopped at PLAYER_REGEN_DISABLED, before
-- lockdown, so the frame doesn't follow the cursor all fight.
frame._scripts.OnMouseDown(frame, "LeftButton")
StakeoutDB.framePos = nil
WoW.fire("PLAYER_REGEN_DISABLED")
check(not frame._moving, "combat start stops a drag in progress")
check(StakeoutDB.framePos ~= nil, "and saves where it was")

-- If lockdown won the race, the drag is finished when combat ends.
frame._scripts.OnMouseDown(frame, "LeftButton")
check(frame._moving, "a drag starts out of combat")
WoW.combat = true
frame._scripts.OnMouseUp(frame, "LeftButton")
check(frame._moving, "releasing in combat can't stop the protected frame")
WoW.combat = false
StakeoutDB.framePos = nil
WoW.fire("PLAYER_REGEN_ENABLED")
check(not frame._moving, "combat end stops it")
check(StakeoutDB.framePos ~= nil, "and saves the position")

-- The event handler for every event the addon registers
for _, event in ipairs({ "PLAYER_LOGIN", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
                          "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_NAME_UPDATE", "UNIT_DIED",
                          "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
    local registered = false
    for _, f in ipairs(WoW.frames) do if f._events[event] then registered = true end end
    check(registered, event .. " is registered")
end
check(WoW.ticker ~= nil and pcall(WoW.ticker.fn), "the sweep ticker runs")

done("test_frames")
