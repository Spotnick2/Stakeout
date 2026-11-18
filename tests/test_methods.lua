------------------------------------------------------------
-- test_methods.lua - every widget method Stakeout calls exists on that
-- widget type in the pinned build (Kit.checkMethods).
--
-- The exercise: both looks (WoW Forever, then glass with the LibGlass
-- checkout), every registered event, sightings by plate, target and
-- mouseover, a death, quest targets with a quest in the log, the range
-- tooltip, the settings and export windows with every script on every frame
-- (hover, click, drag, values) and every dropdown item, every slash command,
-- the sweep ticker and the timers, and combat in and out.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local ARGS = {
    OnClick = { "LeftButton", false }, OnMouseDown = { "LeftButton" }, OnMouseUp = { "LeftButton" },
    OnDragStart = { "LeftButton" }, OnValueChanged = { 1.5, true }, OnUpdate = { 0.6 },
    OnTextChanged = { true }, OnEnterPressed = {}, OnEscapePressed = {},
}

-- Run every script of every frame made so far, as the player would reach it
-- (out of combat: test_frames covers what combat refuses).
local function poke()
    local frames = {}
    for i, f in ipairs(WoW.frames) do frames[i] = f end   -- handlers create frames
    for _, f in ipairs(frames) do
        for script, fn in pairs(f._scripts) do
            if script ~= "OnEvent" then
                local args = ARGS[script] or {}
                fn(f, args[1], args[2])
            end
        end
    end
end

local function dropdowns()
    for _, dd in ipairs({ StakeoutSoundDropdown, StakeoutLookDropdown }) do
        if dd and dd.initFn then
            WoW.dropdownItems = {}
            dd.initFn()
            local items = WoW.dropdownItems
            for _, info in ipairs(items) do if info.func then info.func() end end
        end
    end
end

local function session(saved)
    WoW.dropEvents()
    WoW.combat = false
    return WoW.loadAddon({ savedDB = saved })
end

-- The client a sighting needs: plates, a target, the mouseover, a spellbook
-- and items for the range tooltip, a quest in the log.
local function world()
    WoW.spellbook = { { id = 3044, name = "Arcane Shot", maxRange = 30, harmful = true },
                      { id = 2061, name = "Flash Heal", maxRange = 40, helpful = true } }
    WoW.itemRanges = { [10699] = 10 }
    WoW.questLog = {
        { header = true, title = "Durotar" },
        { questID = 100, title = "Vile Familiars",
          rows = { { text = "Vile Familiar slain: 0/8", type = "monster", numRequired = 8 } } },
    }
    WoW.SetUnit("nameplate1", { name = "Rare Mob", guid = "Creature-0-1-2-3-100-A", plate = true, attackable = true })
    WoW.SetUnit("nameplate2", { name = "Vile Familiar", guid = "Creature-0-1-2-3-3101-B", plate = true,
                                attackable = true, related = true })
    WoW.SetUnit("target", { name = "Other Mob", guid = "Creature-0-1-2-3-101-C", attackable = false })
    WoW.SetUnit("mouseover", { name = "Rare Mob", guid = "Creature-0-1-2-3-100-A", attackable = true })
    WoW.distance = { nameplate1 = 12, nameplate2 = 35, target = 5, mouseover = 12 }
end

local function exercise()
    world()
    WoW.fireAllRegistered()
    WoW.flushTimers()
    SlashCmdList.STAKEOUT("add Rare Mob; Other Mob; Vile Familiar")
    SlashCmdList.STAKEOUT("quests on")
    WoW.fire("QUEST_LOG_UPDATE")
    WoW.flushTimers()
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    WoW.fire("PLAYER_TARGET_CHANGED")
    WoW.fire("UPDATE_MOUSEOVER_UNIT")
    WoW.fire("UNIT_NAME_UPDATE", "nameplate1")
    WoW.flushTimers()
    if WoW.ticker then WoW.ticker.fn() end
    SlashCmdList.STAKEOUT("config")
    SlashCmdList.STAKEOUT("export")
    poke()
    dropdowns()
    if StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM then StaticPopupDialogs.STAKEOUT_CLEAR_CONFIRM.OnAccept() end
    SlashCmdList.STAKEOUT("add Rare Mob; Other Mob")
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    for _, cmd in ipairs({ "", "list", "remove Other Mob", "remove Nobody", "remove", "macro", "macro on",
                           "add Other Mob", "macro off", "export", "look", "look glass", "look forever",
                           "quests", "quests off", "quests on", "reset", "help" }) do
        SlashCmdList.STAKEOUT(cmd)
        WoW.flushTimers()
    end
    -- Combat: in, the target frame's events, out (the deferred refresh).
    WoW.fire("PLAYER_REGEN_DISABLED")
    WoW.combat = true
    WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    WoW.combat = false
    WoW.fire("PLAYER_REGEN_ENABLED")
    WoW.units.nameplate1 = nil
    WoW.fire("UNIT_DIED", "Creature-0-1-2-3-100-A")
    WoW.advance(120)
    if WoW.ticker then WoW.ticker.fn() end
    poke()
    SlashCmdList.STAKEOUT("clear")
end

-- WoW Forever's look, then glass (the library's methods).
session({ svLoadCheck = 1 })
exercise()
WoW.chat = {}
session({ svLoadCheck = 1, theme = "glass" })
check(WoW.ns.theme.Active() == "glass", "the second session wears glass")
exercise()

-- The floor is what the exercise records today (118 recorded), rounded
-- down: it keeps the exercise from quietly shrinking.
local recorded = Kit.checkMethods()
check(recorded >= 110, "the exercise reached the windows (" .. recorded .. " recorded)")

done("test_methods")
