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
        for script, fn in pairs(f.scripts) do
            if not SKIP[script] then
                local args = ARGS[script] or {}
                local ok, err = pcall(fn, f, args[1], args[2])
                H.check(ok, label .. ": " .. tostring(f.name or f.kind) .. " " .. script .. " - " .. tostring(err))
                ran = ran + 1
            end
        end
    end
    return ran
end

local ran = fireAll("out of combat")
H.check(ran > 40, "handlers were actually executed (" .. ran .. ")")

-- The sound dropdown's items, each previewing its sound.
local dd = StakeoutSoundDropdown
WoW.dropdownItems = {}
dd.initFn()
H.eq(#WoW.dropdownItems, 17, "17 built-in sounds without DBM-Core (the 9 path sounds are gone)")
for _, info in ipairs(WoW.dropdownItems) do
    H.check(pcall(info.func), "dropdown item " .. tostring(info.text))
end
WoW.addonsLoaded["DBM-Core"] = true
WoW.dropdownItems = {}
dd.initFn()
H.eq(#WoW.dropdownItems, 24, "plus 7 with DBM-Core")

-- A refused sound falls back to Raid Warning.
WoW.sounds = {}
WoW.refuseSound[8826] = true
StakeoutDB.soundChoice = "Loatheb: I See You"
SlashCmdList.STAKEOUT("add Other Mob")   -- fireAll clicked every row's delete button
WoW.SetUnit("nameplate2", { name = "Other Mob", guid = "Creature-2", plate = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
H.eq(WoW.sounds[#WoW.sounds], 8959, "a refused alert sound falls back to Raid Warning")

-- Clear-all confirmation
H.check(StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM ~= nil, "Clear All asks first")
H.check(pcall(StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM.OnAccept), "confirming Clear All runs")
H.eq(#StakeoutDB.npcList, 0, "and clears the list")

------------------------------------------------------------
-- In combat: the protected target frame must not be touched
------------------------------------------------------------
SlashCmdList.STAKEOUT("add Rare Mob")
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local frame = T.frame()
WoW.inCombat = true
H.check(pcall(frame.scripts.OnMouseDown, frame, "LeftButton"), "a drag attempt in combat is ignored")
H.check(not frame.moving, "and doesn't start moving")
fireAll("in combat")
for _, event in ipairs({ "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_DIED" }) do
    H.check(pcall(WoW.fire, event, "nameplate1"), event .. " in combat")
end
WoW.inCombat = false
H.check(pcall(WoW.fire, "PLAYER_REGEN_ENABLED"), "combat end")

-- A drag held as combat starts is stopped at PLAYER_REGEN_DISABLED, before
-- lockdown, so the frame doesn't follow the cursor all fight.
frame.scripts.OnMouseDown(frame, "LeftButton")
StakeoutDB.framePos = nil
WoW.fire("PLAYER_REGEN_DISABLED")
H.check(not frame.moving, "combat start stops a drag in progress")
H.check(StakeoutDB.framePos ~= nil, "and saves where it was")

-- If lockdown won the race, the drag is finished when combat ends.
frame.scripts.OnMouseDown(frame, "LeftButton")
H.check(frame.moving, "a drag starts out of combat")
WoW.inCombat = true
frame.scripts.OnMouseUp(frame, "LeftButton")
H.check(frame.moving, "releasing in combat can't stop the protected frame")
WoW.inCombat = false
StakeoutDB.framePos = nil
WoW.fire("PLAYER_REGEN_ENABLED")
H.check(not frame.moving, "combat end stops it")
H.check(StakeoutDB.framePos ~= nil, "and saves the position")

-- The event handler for every event the addon registers
for _, event in ipairs({ "PLAYER_LOGIN", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
                          "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_NAME_UPDATE", "UNIT_DIED",
                          "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
    local registered = false
    for _, evs in pairs(WoW.events) do if evs[event] then registered = true end end
    H.check(registered, event .. " is registered")
end
H.check(WoW.ticker ~= nil and pcall(WoW.ticker.fn), "the sweep ticker runs")

H.done("test_frames")
