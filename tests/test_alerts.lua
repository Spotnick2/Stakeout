------------------------------------------------------------
-- test_alerts.lua - #94: Shift+right-click on a quest button arms an alert
-- for its target, which plays when one appears on a nameplate. The click
-- runs nothing secure (shift-type2 = ATTRIBUTE_NOOP) and toggles on the edge
-- the secure action uses; the alert follows the watch list's quiet and
-- re-arm rules, and the members of its target through a new spelling. The
-- cases come from the plan's six Codex rounds.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local T, ns = WoW.loadAddon({ savedDB = { questTargets = true, questHunt = true } })
local Q, QT = ns.quests, ns.quests._test
local REARM, LINGER = ns.core.REARM, ns.core.LINGER
WoW.flushTimers()

local MAP = 1411
local function stand() WoW.position = { map = MAP, x = 0.5, y = 0.5 } end

-- A plain provider: creature objectives by ID, every spawn 10 yd away.
local data = { objectives = {}, names = {} }
local function provider()
    ns.questData = {
        Objectives = function(id) return data.objectives[id] end,
        ItemDroppers = function() return {} end,
        NpcName = function(id) return data.names[id] end,
        FinishedBy = function() return {} end,
        Spawns = function(id) return data.names[id] and { [MAP] = { { 0.5, 0.51 } } } or nil end,
    }
end

local function guid(id, spawn) return string.format("Creature-0-1-2-3-%d-%s", id, spawn or "A") end

-- quests: { { questID, { { id, name }, ... } }, ... }: each a kill objective per mob.
local function quests(list)
    WoW.questLog = {}
    for pos, q in ipairs(list) do
        local rows, objs = {}, {}
        for i, mob in ipairs(q[2]) do
            data.names[mob[1]] = mob[2]
            rows[i] = { type = "monster", text = "0/5 " .. mob[2] .. " slain", finished = false,
                        numFulfilled = 0, numRequired = 5 }
            objs[i] = { kind = "creature", id = mob[1], name = mob[2] }
        end
        data.objectives[q[1]] = objs
        WoW.questLog[pos] = { questID = q[1], title = "Quest " .. q[1], rows = rows }
    end
    Q.Rebuild()
    WoW.flushTimers()
end

local function clean()
    for k in pairs(T.detected) do T.detected[k] = nil end
    for k in pairs(T.announced) do T.announced[k] = nil end
    for i = #QT.alerts, 1, -1 do QT.alerts[i] = nil end
    WoW.units, WoW.chat, WoW.sounds, WoW.combat = {}, {}, {}, false
    WoW.shiftDown, WoW.ctrlDown, WoW.altDown, WoW.useKeyDown = false, false, false, true
    WoW.mapSizes[MAP] = { 1000, 1000 }
    stand()
    StakeoutDB.enableMarking, StakeoutDB.npcList = true, {}
    data.objectives, data.names = {}, {}
    provider()
    WoW.questLog = {}
    Q.Rebuild()
    for _, m in pairs(QT.members) do m.lastSeen = nil end
    WoW.advance(LINGER + 1)
    Q.Tick()
    WoW.chat, WoW.sounds = {}, {}
end

local function button(name)
    for _, b in ipairs(T.buttons) do if b._shown and b.npcName == name then return b end end
end
local function detections(name)
    local n = 0
    for _, line in ipairs(WoW.chat) do
        if line:find("Detected: " .. name, 1, true) then n = n + 1 end
    end
    return n
end
local function plate(token, name, g)
    WoW.SetUnit(token, { name = name, guid = g, plate = true, attackable = true })
    WoW.fire("NAME_PLATE_UNIT_ADDED", token)
end
local function unplate(token)
    WoW.units[token] = nil
    WoW.fire("NAME_PLATE_UNIT_REMOVED", token)
end
local function died(token, g)
    if token then WoW.units[token] = nil end
    WoW.fire("UNIT_DIED", g)
end

-- A click as the client runs it: both edges, Shift / Ctrl as given on each.
local function click(btn, mouse, downMods, upMods)
    WoW.shiftDown, WoW.ctrlDown = downMods.shift or false, downMods.ctrl or false
    WoW.click(btn, mouse, true)
    WoW.shiftDown, WoW.ctrlDown = upMods.shift or false, upMods.ctrl or false
    WoW.click(btn, mouse, false)
    WoW.shiftDown, WoW.ctrlDown = false, false
end
local SHIFT = { shift = true }
local NONE = {}
local function shiftRight(btn) click(btn, "RightButton", SHIFT, SHIFT) end

------------------------------------------------------------
-- The click: no secure action, a toggle on the action's edge
------------------------------------------------------------
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
local bw = button("Bloodscalp Warrior")
check(bw, "a hunt button for an unseen quest mob")
eq(bw:GetAttribute("shift-type2"), "", "a quest button: shift-type2 is ATTRIBUTE_NOOP")
check(bw.bell and not bw.bell._shown, "...its alert mark hidden")

WoW.secureActions = {}
shiftRight(bw)
eq(#WoW.secureActions, 0, "Shift+right-click: nothing secure runs (no target, no mark)")
check(Q.AlertOn("Bloodscalp Warrior"), "...the alert is on")
check(bw.bell._shown, "...the mark shows")
check(WoW.chatText():find("Alert on: Bloodscalp Warrior", 1, true), "...and chat says so")
shiftRight(bw)
check(not Q.AlertOn("Bloodscalp Warrior") and not bw.bell._shown, "again: off, the mark hidden")
check(WoW.chatText():find("Alert off: Bloodscalp Warrior", 1, true), "...and chat says so")

WoW.secureActions = {}
click(bw, "RightButton", NONE, NONE)
eq(#WoW.secureActions, 1, "a plain right-click still runs its macro")
check((WoW.secureActions[1].macrotext or ""):find("/targetexact Bloodscalp Warrior", 1, true), "...the target macro")
check(not Q.AlertOn("Bloodscalp Warrior"), "...and toggles nothing")

-- Shift pressed or released between the edges: a target or a toggle, never both.
for _, keyDown in ipairs({ true, false }) do
    WoW.useKeyDown = keyDown
    for _, case in ipairs({ { NONE, SHIFT }, { SHIFT, NONE } }) do
        WoW.secureActions = {}
        local before = Q.AlertOn("Bloodscalp Warrior")
        click(bw, "RightButton", case[1], case[2])
        local acted, toggled = #WoW.secureActions > 0, Q.AlertOn("Bloodscalp Warrior") ~= before
        check(acted ~= toggled, ("ActionButtonUseKeyDown %s, Shift %s: a target or a toggle, not both (acted %s, toggled %s)")
            :format(tostring(keyDown), case[1] == SHIFT and "on the down edge only" or "on the up edge only",
                tostring(acted), tostring(toggled)))
        if toggled then shiftRight(bw) end   -- back off
    end
end
WoW.useKeyDown = true

click(bw, "RightButton", { shift = true, ctrl = true }, { shift = true, ctrl = true })
check(not Q.AlertOn("Bloodscalp Warrior"), "Ctrl+Shift+right-click: no toggle")

-- Marking off: no right-click macro of its own, the same toggle.
StakeoutDB.enableMarking = false
Q.Rebuild()
WoW.flushTimers()
bw = button("Bloodscalp Warrior")
WoW.secureActions = {}
shiftRight(bw)
eq(#WoW.secureActions, 0, "marking off: Shift+right-click runs nothing secure either")
check(Q.AlertOn("Bloodscalp Warrior"), "...and toggles")
shiftRight(bw)
WoW.secureActions = {}
click(bw, "RightButton", NONE, NONE)
eq(#WoW.secureActions, 1, "...a plain right-click still targets")
StakeoutDB.enableMarking = true
Q.Rebuild()
WoW.flushTimers()
bw = button("Bloodscalp Warrior")

-- In combat: a Lua flag and a region, nothing protected.
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
WoW.blocked = {}
local writes = 0
local realSet = getmetatable(bw).__index.SetAttribute
bw.SetAttribute = function(self, k, v) writes = writes + 1 return realSet(self, k, v) end
shiftRight(bw)
check(Q.AlertOn("Bloodscalp Warrior") and bw.bell._shown, "in combat: the toggle works, the mark shows")
eq(writes, 0, "...no attribute written")
eq(#WoW.blocked, 0, "...nothing refused")
shiftRight(bw)
bw.SetAttribute = nil
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")

-- A watch button: the old fallback, no toggle.
SlashCmdList.STAKEOUT("add Rare Mob")
plate("nameplate9", "Rare Mob", guid(999))
local rare = button("Rare Mob")
eq(rare:GetAttribute("shift-type2"), nil, "a watch button: no shift-type2")
WoW.chat = {}
shiftRight(rare)
check(not Q.AlertOn("Rare Mob") and not rare.bell._shown, "...and Shift+right-click toggles nothing on it")
eq(#WoW.chat, 0, "...nor says anything: it isn't a quest button")
unplate("nameplate9")
SlashCmdList.STAKEOUT("remove Rare Mob")
WoW.advance(LINGER + 2)

-- One button, watch then quest then watch: shift-type2 follows.
clean()
SlashCmdList.STAKEOUT("add Rare Mob")
plate("nameplate9", "Rare Mob", guid(999))
local first = T.buttons[1]
eq(first.npcName, "Rare Mob", "button 1: the watch list's")
eq(first:GetAttribute("shift-type2"), nil, "...no shift-type2")
unplate("nameplate9")
SlashCmdList.STAKEOUT("remove Rare Mob")
WoW.advance(LINGER + 2)
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
eq(first.npcName, "Bloodscalp Warrior", "button 1 reused for a quest mob")
eq(first:GetAttribute("shift-type2"), "", "...shift-type2 written")
quests({})
SlashCmdList.STAKEOUT("add Rare Mob")
plate("nameplate9", "Rare Mob", guid(999))
eq(first.npcName, "Rare Mob", "...and back to the watch list")
eq(first:GetAttribute("shift-type2"), nil, "...shift-type2 cleared")
unplate("nameplate9")
SlashCmdList.STAKEOUT("remove Rare Mob")

------------------------------------------------------------
-- The trigger: a plate arrives
------------------------------------------------------------
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
WoW.chat, WoW.sounds = {}, {}
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
eq(detections("Bloodscalp Warrior"), 1, "armed, a plate arrives: one alert")
eq(#WoW.sounds, 1, "...with its sound")
plate("nameplate2", "Bloodscalp Warrior", guid(701, "B"))
eq(detections("Bloodscalp Warrior"), 1, "a second plate of it: nothing more")
-- Leaving and coming back within REARM: quiet; after it: an alert.
unplate("nameplate1"); unplate("nameplate2")
WoW.advance(10)
plate("nameplate1", "Bloodscalp Warrior", guid(701, "C"))
eq(detections("Bloodscalp Warrior"), 1, "back within REARM: quiet (a plate at the edge alerts once)")
unplate("nameplate1")
WoW.advance(REARM + 1)
plate("nameplate1", "Bloodscalp Warrior", guid(701, "D"))
eq(detections("Bloodscalp Warrior"), 2, "back after REARM: an alert")
unplate("nameplate1")
WoW.advance(REARM + 1)
-- Target or mouseover alone: you're already looking at it.
WoW.SetUnit("target", { name = "Bloodscalp Warrior", guid = guid(701, "E"), attackable = true })
WoW.fire("PLAYER_TARGET_CHANGED")
eq(detections("Bloodscalp Warrior"), 2, "the target alone: no alert")
WoW.units.target = nil
WoW.fire("PLAYER_TARGET_CHANGED")

-- Deaths: the one whose plate went last re-arms at once, in either order.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
died("nameplate1", guid(701, "A"))
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
WoW.chat = {}
plate("nameplate2", "Bloodscalp Warrior", guid(701, "B"))
eq(detections("Bloodscalp Warrior"), 1, "death, then the plate's removal: the respawn alerts at once")
WoW.units.nameplate2 = nil
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
died(nil, guid(701, "B"))
WoW.chat = {}
plate("nameplate3", "Bloodscalp Warrior", guid(701, "C"))
eq(detections("Bloodscalp Warrior"), 1, "removal, then the death: the respawn alerts at once too")
unplate("nameplate3")
died(nil, guid(701, "Z"))
WoW.chat = {}
plate("nameplate3", "Bloodscalp Warrior", guid(701, "D"))
eq(detections("Bloodscalp Warrior"), 0, "an unrelated death keeps the quiet")
unplate("nameplate3")

-- A and B: A's plate goes, then B's. Only B's death re-arms.
for _, who in ipairs({ "A", "B" }) do
    clean()
    quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
    shiftRight(button("Bloodscalp Warrior"))
    plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
    plate("nameplate2", "Bloodscalp Warrior", guid(701, "B"))
    unplate("nameplate1")
    unplate("nameplate2")
    died(nil, guid(701, who))
    WoW.chat = {}
    plate("nameplate3", "Bloodscalp Warrior", guid(701, "C"))
    eq(detections("Bloodscalp Warrior"), who == "B" and 1 or 0,
        who .. "'s late death (A's plate went first, B's last): " .. (who == "B" and "re-armed" or "still quiet"))
end

-- Two plates gone before one tick: which went last is unknown, the quiet holds.
for _, who in ipairs({ "A", "B" }) do
    clean()
    quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
    shiftRight(button("Bloodscalp Warrior"))
    plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
    plate("nameplate2", "Bloodscalp Warrior", guid(701, "B"))
    WoW.units.nameplate1, WoW.units.nameplate2 = nil, nil   -- no removal events
    Q.Tick()
    died(nil, guid(701, who))
    WoW.chat = {}
    plate("nameplate3", "Bloodscalp Warrior", guid(701, "C"))
    eq(detections("Bloodscalp Warrior"), 0, "two plates gone in one tick, then " .. who .. "'s death: still quiet")
end

-- Toggled on while one is in view: nothing until it leaves and comes back.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
shiftRight(button("Bloodscalp Warrior"))
eq(detections("Bloodscalp Warrior"), 0, "armed while one is in view: no alert")
plate("nameplate2", "Bloodscalp Warrior", guid(701, "B"))
eq(detections("Bloodscalp Warrior"), 0, "...nor for a second one")
died("nameplate1", guid(701, "A")); died("nameplate2", guid(701, "B"))
plate("nameplate3", "Bloodscalp Warrior", guid(701, "C"))
eq(detections("Bloodscalp Warrior"), 1, "...the next arrival alerts")
unplate("nameplate3")
shiftRight(button("Bloodscalp Warrior"))
WoW.advance(REARM + 1)
plate("nameplate3", "Bloodscalp Warrior", guid(701, "D"))
eq(detections("Bloodscalp Warrior"), 1, "off: no alert")

------------------------------------------------------------
-- The watch list and the quests: one alert per arrival
------------------------------------------------------------
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
SlashCmdList.STAKEOUT("add Bloodscalp Warrior")
WoW.chat = {}
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
eq(detections("Bloodscalp Warrior"), 1, "watched and armed: one alert on one plate")
-- The watch list's quiet outlasts the quests' (the target kept it 20 s more):
-- coming back between the two, the quest alert plays alone.
WoW.SetUnit("target", { name = "Bloodscalp Warrior", guid = guid(701, "A"), attackable = true })
WoW.fire("PLAYER_TARGET_CHANGED")
unplate("nameplate1")
WoW.advance(20)
WoW.units.target = nil
WoW.fire("PLAYER_TARGET_CHANGED")
WoW.advance(REARM - 20 + 5)
WoW.chat = {}
plate("nameplate1", "Bloodscalp Warrior", guid(701, "B"))
eq(detections("Bloodscalp Warrior"), 1, "the watch list still quiet, the quests' not: one alert, not none")
unplate("nameplate1")
-- Two units of the name in one moment: the watch list announces one (target),
-- the armed quest alert the other (plate).
WoW.advance(REARM * 3)
for k in pairs(T.detected) do T.detected[k] = nil end
for k in pairs(T.announced) do T.announced[k] = nil end
WoW.chat = {}
WoW.SetUnit("target", { name = "Bloodscalp Warrior", guid = guid(701, "C"), attackable = true })
WoW.fire("PLAYER_TARGET_CHANGED")
plate("nameplate2", "Bloodscalp Warrior", guid(701, "D"))
eq(detections("Bloodscalp Warrior"), 2, "two units at one time: the watch list's alert and the quests'")
WoW.units.target = nil
WoW.fire("PLAYER_TARGET_CHANGED")
unplate("nameplate2")
SlashCmdList.STAKEOUT("remove Bloodscalp Warrior")

------------------------------------------------------------
-- Names: a new spelling, a merged member, two records meeting, Guard/Sentry
------------------------------------------------------------
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
plate("nameplate1", "Bloodscalp Warrior ", guid(701, "A"))   -- the client's spelling
eq(detections("Bloodscalp Warrior"), 1, "armed as a hunt button, first seen under another spelling: one alert")
check(Q.AlertOn("Bloodscalp Warrior "), "...the alert follows the new name")
check(button("Bloodscalp Warrior ") and button("Bloodscalp Warrior ").bell._shown, "...and its button keeps the mark")
unplate("nameplate1")

-- Another ID merged into the armed button (the same name), first seen under
-- another spelling.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
quests({ { 1, { { 701, "Bloodscalp Warrior" } } }, { 2, { { 702, "Bloodscalp Warrior" } } } })
plate("nameplate1", "Bloodscalp Warrior (elite)", guid(702, "A"))
eq(detections("Bloodscalp Warrior"), 1, "a member merged in after arming, seen under another name: one alert")
unplate("nameplate1")

-- Two armed hunt buttons whose first plate shows one name, in combat: one
-- record, one alert, one toggle, and both marks go.
clean()
quests({ { 1, { { 801, "Kobold Worker" }, { 802, "Kobold Laborer" } } } })
local kw, kl = button("Kobold Worker"), button("Kobold Laborer")
shiftRight(kw); shiftRight(kl)
eq(#QT.alerts, 2, "two armed buttons: two records")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
plate("nameplate1", "Kobold Laborer", guid(801, "A"))
eq(#QT.alerts, 1, "the Worker seen as \"Kobold Laborer\": the records merge")
eq(detections("Kobold"), 1, "...one alert")
check(kw.bell._shown and kl.bell._shown, "...both buttons (the layout waits for the fight) keep the mark")
shiftRight(kw)
eq(#QT.alerts, 0, "one toggle turns it off")
check(not kw.bell._shown and not kl.bell._shown, "...and both marks go, in combat")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
unplate("nameplate1")

-- Guard and Sentry: two IDs, one provider name; one was seen as Sentry, so
-- two buttons. Arming Guard covers only Guard.
clean()
quests({ { 1, { { 811, "Guard" }, { 812, "Guard" } } } })
plate("nameplate1", "Sentry", guid(812, "A"))
unplate("nameplate1")
for _, m in pairs(QT.members) do m.lastSeen = nil end
Q.Tick()
check(button("Guard") and button("Sentry"), "two buttons: Guard and Sentry")
shiftRight(button("Guard"))
check(not Q.AlertOn("Sentry"), "arming Guard doesn't arm Sentry")
WoW.advance(REARM + 1)
plate("nameplate2", "Sentry", guid(812, "B"))
eq(detections("Sentry"), 0, "Sentry's plate: no alert")
plate("nameplate3", "Guard", guid(811, "A"))
eq(detections("Guard"), 1, "Guard's plate, with Sentry still in view: Guard's alert")
unplate("nameplate2"); unplate("nameplate3")

------------------------------------------------------------
-- A plate reused for another spawn, seen first by the tick
------------------------------------------------------------
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
WoW.SetUnit("nameplate1", { name = "Bloodscalp Warrior", guid = guid(701, "B"), plate = true, attackable = true })
Q.Tick()
eq(QT.members["id:701"].tokens.nameplate1, guid(701, "B"), "the tick reads the plate's new spawn")
died(nil, guid(701, "A"))
check(QT.alerts[1].plated, "the old spawn's late death leaves the live plate")
WoW.chat = {}
Q.Tick()
eq(detections("Bloodscalp Warrior"), 0, "...and nothing alerts")
died("nameplate1", guid(701, "B"))
plate("nameplate2", "Bloodscalp Warrior", guid(701, "C"))
eq(detections("Bloodscalp Warrior"), 1, "the live one's own death re-arms it")
unplate("nameplate2")
-- No death for the old one: its GUID goes after LINGER, not held forever.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
WoW.SetUnit("nameplate1", { name = "Bloodscalp Warrior", guid = guid(701, "B"), plate = true, attackable = true })
Q.Tick()
WoW.advance(LINGER + 2)
Q.Tick()
eq(QT.members["id:701"].guids[guid(701, "A")], nil, "the old spawn's GUID expires after LINGER")
died("nameplate1", guid(701, "B"))
eq(next(QT.members["id:701"].guids), nil, "...so the live one's death ends the sighting")

------------------------------------------------------------
-- Lifetime
------------------------------------------------------------
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
SlashCmdList.STAKEOUT("layout list")
check(Q.AlertOn("Bloodscalp Warrior") and button("Bloodscalp Warrior").bell._shown, "a re-layout keeps it, and its mark")
SlashCmdList.STAKEOUT("layout icons")
-- The button going away (hunt off) keeps it: it still alerts.
Q.SetHunt(false)
WoW.flushTimers()
eq(button("Bloodscalp Warrior"), nil, "hunt off: no button")
check(Q.AlertOn("Bloodscalp Warrior"), "...the alert stays")
WoW.chat = {}
plate("nameplate1", "Bloodscalp Warrior", guid(701, "A"))
eq(detections("Bloodscalp Warrior"), 1, "...and plays on a plate")
unplate("nameplate1")
Q.SetHunt(true)
WoW.flushTimers()
-- The quest abandoned: gone.
quests({})
check(not Q.AlertOn("Bloodscalp Warrior"), "the quest abandoned: the alert goes")

-- Another quest unit: no owning quest, kept until toggled off.
clean()
Q.SetOther(true)
WoW.flushTimers()
WoW.SetUnit("nameplate1", { name = "Venomtail Raptor", guid = guid(3254), plate = true, related = true, attackable = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
shiftRight(button("Venomtail Raptor"))
check(Q.AlertOn("Venomtail Raptor"), "another quest unit: armed")
unplate("nameplate1")
WoW.advance(LINGER + 2)
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
check(Q.AlertOn("Venomtail Raptor"), "...kept through an unrelated rebuild, its member gone")
Q.SetOther(false)
WoW.flushTimers()

-- Quest targets off in combat, then a click on the stale button.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
bw = button("Bloodscalp Warrior")
shiftRight(bw)
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
Q.SetEnabled(false)
check(not bw.bell._shown, "quests off in combat: the mark goes at once")
check(bw._shown, "...the button stays until the fight ends")
shiftRight(bw)
check(not Q.AlertOn("Bloodscalp Warrior") and not bw.bell._shown, "...a click on it arms nothing")
check(WoW.chatText():find("isn't a quest target any more", 1, true), "...and says why")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
Q.SetEnabled(true)
WoW.flushTimers()

-- The objective done in combat: the button stays until the fight ends, and a
-- click on it arms nothing.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
bw = button("Bloodscalp Warrior")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
local done5 = WoW.questLog[1].rows[1]
done5.finished, done5.numFulfilled, done5.text = true, 5, "5/5 Bloodscalp Warrior slain"
Q.Rebuild()
check(bw._shown and bw.npcName == "Bloodscalp Warrior", "an objective done in combat: its button stays for now")
WoW.chat = {}
shiftRight(bw)
check(not Q.AlertOn("Bloodscalp Warrior") and not bw.bell._shown, "...a click on it arms nothing")
check(WoW.chatText():find("isn't a quest target any more", 1, true), "...and says why")
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")

------------------------------------------------------------
-- Codex on the code: Unknown, a frozen button, a rescan, a merged "other"
------------------------------------------------------------
-- Two armed mobs both "Unknown" for a moment stay two records.
clean()
quests({ { 1, { { 801, "Kobold Worker" }, { 802, "Kobold Laborer" } } } })
shiftRight(button("Kobold Worker")); shiftRight(button("Kobold Laborer"))
plate("nameplate1", "Unknown", guid(801, "A"))
plate("nameplate2", "Unknown", guid(802, "A"))
eq(#QT.alerts, 2, "two armed mobs both \"Unknown\" for a moment: still two records")
check(not Q.AlertOn("Unknown"), "...and \"Unknown\" is no record's name")
unplate("nameplate1"); unplate("nameplate2")

-- A hunt button frozen by combat, its mob since seen under another spelling:
-- arming it takes the name the member has now.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
bw = button("Bloodscalp Warrior")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
plate("nameplate1", "Bloodscalp Warrior ", guid(701, "A"))
died("nameplate1", guid(701, "A"))
WoW.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
eq(bw.npcName, "Bloodscalp Warrior", "in combat the button keeps its old name")
shiftRight(bw)
WoW.combat = false
WoW.fire("PLAYER_REGEN_ENABLED")
for _, m in pairs(QT.members) do m.lastSeen = nil end
Q.Tick()
local renamed = button("Bloodscalp Warrior ")
check(renamed and Q.AlertOn("Bloodscalp Warrior ") and renamed.bell._shown,
    "after combat the renamed button shows the alert on")

-- A rescan: the watch list announces one name on the target, a plate shows the
-- record's other spelling. Only the watch list's own sighting is skipped.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
shiftRight(button("Bloodscalp Warrior"))
plate("nameplate1", "Bloodscalp Warrior x", guid(701, "A"))
unplate("nameplate1")
WoW.advance(REARM + 1)
SlashCmdList.STAKEOUT("add Bloodscalp Warrior")
for k in pairs(T.detected) do T.detected[k] = nil end
for k in pairs(T.announced) do T.announced[k] = nil end
WoW.SetUnit("nameplate1", { name = "Bloodscalp Warrior x", guid = guid(701, "B"), plate = true, attackable = true })
WoW.SetUnit("target", { name = "Bloodscalp Warrior", guid = guid(701, "C"), attackable = true })
WoW.chat = {}
Q.Rebuild()
eq(detections("Bloodscalp Warrior x"), 1, "a rescan: the plate's own alert plays although the watch list announced the other name")
WoW.units = {}
SlashCmdList.STAKEOUT("remove Bloodscalp Warrior")

-- An armed mob's plate before the client has named it: the chat line has its
-- real name, never "Unknown"; and a button showing "Unknown" arms nothing.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" }, { 702, "Kobold Laborer" } } } })
shiftRight(button("Bloodscalp Warrior"))
WoW.chat = {}
plate("nameplate1", "Unknown", guid(701, "A"))
eq(detections("Unknown"), 0, "an unnamed plate of an armed mob: never \"Detected: Unknown\"")
eq(detections("Bloodscalp Warrior"), 1, "...its known name instead")
plate("nameplate2", "Unknown", guid(702, "A"))
local unknownBtn = button("Unknown")
check(unknownBtn, "a button showing the placeholder")
shiftRight(unknownBtn)
check(not Q.AlertOn("Unknown"), "...arms nothing")
-- Both mobs show "Unknown" for now, so one button covers both: a click on it
-- must not reach the armed one's record and turn it off.
check(Q.AlertOn("Bloodscalp Warrior"), "...and leaves the armed mob's alert on")
unplate("nameplate1"); unplate("nameplate2")

-- An "other quest unit" alert merged with a hunt button's keeps its lifetime.
clean()
Q.SetOther(true)
WoW.flushTimers()
quests({ { 1, { { 901, "Raptor Hatchling" } } } })
WoW.SetUnit("nameplate1", { name = "Venomtail Raptor", guid = guid(3254), plate = true, related = true, attackable = true })
WoW.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
shiftRight(button("Venomtail Raptor"))
shiftRight(button("Raptor Hatchling"))
unplate("nameplate1")
plate("nameplate2", "Venomtail Raptor", guid(901, "A"))   -- the hatchling, seen as the raptor
eq(#QT.alerts, 1, "the hunt mob seen under the other unit's name: one record")
unplate("nameplate2")
WoW.questLog[1].rows[1].finished = true
Q.Rebuild()
check(Q.AlertOn("Venomtail Raptor"), "...its objective done, the other unit's alert stays")
Q.SetOther(false)
WoW.flushTimers()

-- The tooltip says what the click does, and the state.
clean()
quests({ { 1, { { 701, "Bloodscalp Warrior" } } } })
bw = button("Bloodscalp Warrior")
bw._scripts.OnEnter(bw)
check(table.concat(GameTooltip._lines or {}, "|"):find("Shift+right-click: alert when one appears", 1, true),
    "the tooltip offers the alert")
shiftRight(bw)
bw._scripts.OnEnter(bw)
check(table.concat(GameTooltip._lines or {}, "|"):find("Alert on", 1, true), "...and says when it's on")
bw._scripts.OnLeave(bw)

done("test_alerts")
