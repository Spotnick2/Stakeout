-- StakeoutProbe: a ForeverProbe module (the host loaded from its checkout).
-- Its commands run on the stubbed client and log what they read, never to
-- chat; its procedures are defined and start. A fake LibQuestieDB stands in
-- for QuestieDB (another addon's global, not a client API). Runs locally only:
-- CI sets FOREVERPROBE_OPTIONAL=1 and this file skips itself.
dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

-- ForeverProbe, as the client loads it before a dependent (GUIDE.md, section 8).
local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
local toc = io.open(root .. "/ForeverProbe.toc", "rb")
if not toc then
    if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
        Kit.skip("test_probe", "ForeverProbe is private and local; the probe tests run locally")
    end
    error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
end
local hostFiles = {}
for line in toc:read("*a"):gmatch("[^\r\n]+") do
    if line:match("%.lua$") and not line:match("^#") then hostFiles[#hostFiles + 1] = root .. "/" .. line end
end
toc:close()

-- The host's own globals and the probe's, nil until they are made.
for _, g in ipairs({ "ForeverProbe", "ForeverProbeDB", "StakeoutProbeDB", "LibQuestieDB", "Questie",
                     "SLASH_FOREVERPROBE1", "SLASH_FOREVERPROBE2" }) do
    WoW.allowGlobal(g)
end

for _, file in ipairs(hostFiles) do assert(loadfile(file))("ForeverProbe", {}) end
WoW.fire("ADDON_LOADED", "ForeverProbe")
local FP = ForeverProbe

--------------------------------------------------------------------------------
-- The client this probe reads (each function below is in the 70450 dump)
--------------------------------------------------------------------------------

WoW.quests = {
    { questID = 100, title = "Vile Familiars", rows = { { text = "0/8 Vile Familiar slain", type = "monster",
        finished = false, numFulfilled = 0, numRequired = 8 } } },
    { questID = 101, title = "Report to Orgnil", rows = {}, complete = true },
}
C_QuestLog = {}
function C_QuestLog.GetNumQuestLogEntries() return #WoW.quests, #WoW.quests end
function C_QuestLog.GetInfo(i)
    local q = WoW.quests[i]
    return q and { questID = q.questID, title = q.title, isHeader = false }
end
function C_QuestLog.GetQuestObjectives(id)
    for _, q in ipairs(WoW.quests) do if q.questID == id then return q.rows end end
    return {}
end
function C_QuestLog.IsComplete(id)
    for _, q in ipairs(WoW.quests) do if q.questID == id then return q.complete == true end end
    return false
end
function C_QuestLog.ReadyForTurnIn(id) return C_QuestLog.IsComplete(id) end
function C_QuestLog.UnitIsRelatedToActiveQuest(token) return token == "target" end

-- Durotar, 5000 x 3333 yd; the player at 52.0, 43.0.
WoW.pos = { map = 1411, x = 0.52, y = 0.43, w = 5000, h = 3333 }
C_Map = {}
function C_Map.GetBestMapForUnit() return WoW.pos.map end
function C_Map.GetPlayerMapPosition() return { GetXY = function() return WoW.pos.x, WoW.pos.y end } end
function C_Map.GetMapWorldSize() return WoW.pos.w, WoW.pos.h end
function UnitPosition() return WoW.pos.x * WoW.pos.w, WoW.pos.y * WoW.pos.h, 0, 1 end
function IsInInstance() return false, "none" end
function UnitCreatureID(token) local u = WoW.units[token] return u and u.creatureID end
function UnitCanAttack(_, token) local u = WoW.units[token] return u and not u.friendly end
function UnitReaction(token) local u = WoW.units[token] return u and (u.friendly and 5 or 2) end
function GetRaidTargetIndex() return nil end
function C_NamePlate.GetNamePlateForUnit(token) local u = WoW.units[token] return u and u.plate and {} or nil end
function debugprofilestop() return WoW.now * 1000 end

-- A QuestieDB with the provider's shape (src/api.lua, src/support/data.lua).
local NPCS = {
    [3142] = { name = "Orgnil Soulscar", spawns = { [14] = { { 52.24, 43.15 } } }, questEnds = { 101 } },
    [3101] = { name = "Vile Familiar", spawns = { [14] = { { 45, 57 }, { 46, 58 } } } },
}
local function entityOf(rows)
    return { Get = function(id, key) return rows[id] and rows[id][key] end }
end
LibQuestieDB = {
    addonName = "QuestieDB", readMode = "baked", contractVersion = 4, minSupportedContract = 4,
    RequireContract = function(n) return n == 4 end,
    Npc = entityOf(NPCS),
    Quest = entityOf({ [100] = { objectives = { { { 3101 } } } }, [101] = { finishedBy = { { 3142 } } } }),
    Item = entityOf({}), Object = entityOf({}),
    ObjectiveFirst = { killCreditObjectiveFirst = {}, itemObjectiveFirst = { [100] = true } },
    EraToForever = function(area, x, y) if area == 215 then return x * 0.8 + 7, y * 0.8 + 13 end return x, y end,
    Support = { Get = function(name)
        if name ~= "ZoneDB" then return nil end
        return { private = {
            areaIdToUiMapId = "return {\n    [14] = 1411, -- Durotar\n    [215] = 1412, -- Mulgore\n}",
            areaIdToUiMapIdOverride = "return {\n    [0] = 0, -- fail-safe\n}",
        } }
    end },
}

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local ns = {}
assert(loadfile("Tools/StakeoutProbe/StakeoutProbe.lua"))("StakeoutProbe", ns)
assert(loadfile("Tools/StakeoutProbe/Hud.lua"))("StakeoutProbe", ns)   -- the TOC's order
assert(loadfile("Tools/StakeoutProbe/Layout.lua"))("StakeoutProbe", ns)
assert(loadfile("Tools/StakeoutProbe/Alert.lua"))("StakeoutProbe", ns)
WoW.fire("ADDON_LOADED", "StakeoutProbe")
WoW.fire("PLAYER_LOGIN")
local T = ns._test
local db = StakeoutProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end

check(T.Probe.log == db.log, "its ForeverProbe log is StakeoutProbeDB.log, bound at ADDON_LOADED")
check(logged("loaded %(1 loads%)"), "loaded")
check(logged("sample PLAYER_LOGIN: 0 plates"), "the login sample")

--------------------------------------------------------------------------------
-- The area map parser: data only, all or nothing
--------------------------------------------------------------------------------

local map, n = T.parseAreaMap("return {\n    [14] = 1411, -- Durotar\n\n    -- a note\n    [2257] = 0,\n}")
eq(n, 2, "two entries")
eq(map and map[14], 1411, "14 -> 1411")
eq(map and map[2257], 0, "an explicit 0 is kept")
check(not T.parseAreaMap("return { [14] = 1411, os.exit() }"), "anything else rejects the whole string")
check(not T.parseAreaMap("{ [14] = 1411 }"), "not a `return { }`")
check(not T.parseAreaMap(nil), "not a string")
eq(T.npcIdFromGuid("Creature-0-4170-1-12-3142-0000ABCD"), 3142, "an NPC ID from a GUID")
eq(T.npcIdFromGuid("Player-4170-0A1B2C3D"), nil, "a player's GUID gives none")
eq(T.npcIdFromGuid(WoW.SECRET), nil, "a secret GUID gives none")

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000ABCD", creatureID = 3142,
    friendly = true })
for _, cmd in ipairs({ "state", "log", "unit", "plates", "spawns", "near", "questie", "mark", "walk",
                       "events on", "events off" }) do
    fp("so " .. cmd)
end
check(logged("position: map 1411 at 52%.00, 43%.00; map 5000 x 3333 yd"), "state: the position")
check(logged("Q 100 Vile Familiars: IsComplete false ReadyForTurnIn false, 1 rows"), "log: a quest")
check(logged("row 1: type monster finished false 0/8 objectiveType nil text \"0/8 Vile Familiar slain\""),
    "log: its row, raw")
check(logged("questie creature: 3101 Vile Familiar"), "log: QuestieDB's objective")
check(logged("questie finishedBy npc %[3142 Orgnil Soulscar%] object %- ; first: none")
    or logged("questie finishedBy npc %[3142 Orgnil Soulscar%]"), "log: the finisher")
check(logged("first: itemObjectiveFirst"), "log: Questie's ordering hint")
check(logged("unit target: name \"Orgnil Soulscar\" .* creatureID 3142 related true attackable false"), "unit")
check(logged("questie npc 3142: name Orgnil Soulscar, same as the client's"), "unit: QuestieDB's name matches")
check(logged("spawns in area 14 %-> uiMap 1411: 1 points %(this map%)"), "spawns: the area mapped to this map")
local nearest = logged("nearest spawn ([%d.]+) yd")
local d = tonumber(nearest and nearest:match("nearest spawn ([%d.]+) yd"))
check(d and d > 12.9 and d < 13.1, "spawns: Orgnil 13 yd away (0.24% of 5000 = 12, 0.15% of 3333 = 5): " .. tostring(d))
check(logged("turnin Orgnil Soulscar %(3142%) for Report to Orgnil"), "near: the turn-in, once complete")
check(logged("kill Vile Familiar %(3101%) for Vile Familiars"), "near: the kill target")
check(logged("RequireContract%(4%) true"), "questie: the contract")
check(logged("area map: 3 areas in"), "questie: the map parsed, with the override's entry added")
check(logged("walk: 0%.0 yd on the map, 0%.0 yd in the world"), "walk: no move")
check(logged("events: logging") and logged("events: stopped"), "events on and off")

-- A player is never logged by name.
WoW.SetUnit("target", { name = "Someone", guid = "Player-4170-0A1B2C3D", player = true })
fp("so unit")
check(logged("unit target: a player %(not logged%)"), "a player target")
check(not logged("Someone"), "...and their name isn't in the log")

-- The test button: left /targetexact, right adds /tm; never changed in combat.
fp("so button Orgnil Soulscar !8")
local b = _G.StakeoutProbeButton
check(b and b._template == "SecureActionButtonTemplate", "a secure button")
eq(b._attrs.macrotext, "/cleartarget\n/targetexact Orgnil Soulscar", "left: target by exact name")
eq(b._attrs.macrotext2, "/cleartarget\n/targetexact Orgnil Soulscar\n/tm !8", "right: and mark")
eq(#b._forClicks, 2, "both mouse edges registered")
-- A click: the secure macro runs (here: the target set by hand), then PostClick logs what it got.
b._scripts.PostClick(b, "LeftButton", true)
check(logged("click LeftButton down: target <a player> %(wanted"), "a player targeted is logged as one")
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000ABCD", creatureID = 3142,
    friendly = true })
b._scripts.PostClick(b, "RightButton", false)
check(logged("click RightButton up: target Orgnil Soulscar %(wanted Orgnil Soulscar%) plate false mark nil "
    .. "dead false unit 0000ABCD"), "a click logs the target it got, alive or not, and which one")
eq(T.state.clicks, 2, "...and counts")
WoW.SetUnit("target", { name = "Orgnil Soulscar", guid = "Creature-0-4170-1-12-3142-0000BEEF", creatureID = 3142,
    dead = true })
b._scripts.PostClick(b, "LeftButton", true)
check(logged("dead true unit 0000BEEF"), "a corpse is logged as one")
eq(T.state.lastClick.dead, true, "...and recorded")
WoW.combat = true
fp("so button Vile Familiar")
eq(b._attrs.macrotext, "/cleartarget\n/targetexact Orgnil Soulscar", "not changed in combat")
check(logged("button: in combat"), "...saying why")
WoW.combat = false
fp("so button off")
eq(b._shown, false, "button off hides it")

--------------------------------------------------------------------------------
-- Procedures
--------------------------------------------------------------------------------

for _, name in ipairs({ "quests", "range", "hostile", "events", "core", "mulgore", "corpse", "look", "rows", "alert" }) do
    fp("steps so " .. name)
    local rec = FP.db.steps.records["StakeoutProbe/" .. name]
    eq(rec and rec.status, "active", "procedure " .. name .. " starts")
    fp("steps stop")
end

-- #94's alert procedure: the click setting it switches comes back (saved
-- once, put back on a stop), and each gesture's expected result.
do
    local A = ns._test.alert
    rawset(_G, "SetCVar", function(k, v) if k == "ActionButtonUseKeyDown" then WoW.useKeyDown = v == "1" end end)
    if type(rawget(_G, "StakeoutProbeDB")) ~= "table" then rawset(_G, "StakeoutProbeDB", {}) end
    WoW.useKeyDown = true
    A.setKeyDown(true)()
    eq(WoW.useKeyDown, false, "the switch flips ActionButtonUseKeyDown")
    A.setKeyDown(true)()
    eq(StakeoutProbeDB.alertKeyDown, true, "Back and Run again: the original stays the one saved first")
    A.restoreOn({ stopped = true })("done")
    eq(WoW.useKeyDown, false, "leaving a switched step by Next keeps it switched")
    A.restoreOn({ stopped = true })("stopped")
    eq(WoW.useKeyDown, true, "Stop puts it back")
    eq(StakeoutProbeDB.alertKeyDown, nil, "...and forgets it")
    A.setKeyDown(true)()
    A.restoreKeyDown()   -- what the first step does after a /reload
    eq(WoW.useKeyDown, true, "a run left switched is put back by the next one")
    -- The gestures: Shift added before release targets at 1 and toggles at 0.
    WoW.SetUnit("target", { name = "Some Mob", guid = "Creature-0-1-2-3-55-A" })
    WoW.useKeyDown = true
    check((A.gesture(true)()), "at 1, Shift added late: a target is right")
    check(not A.gesture(false)(), "at 1, Shift let go early: a target is wrong (it should toggle)")
    WoW.useKeyDown = false
    check(not A.gesture(true)(), "at 0, Shift added late: a target is wrong (it should toggle)")
    check((A.gesture(false)()), "at 0, Shift let go early: a target is right")
    WoW.units.target, WoW.useKeyDown = nil, true
    rawset(_G, "SetCVar", nil)
end

-- The corpse variants set the left-click macro, with the name filled in.
eq(T.aim("Pygmy Surf Crawler", 3106, "8",
    "/cleartarget\n/targetexact <name>\n/cleartarget [dead]\n/targetexact <name>"), true, "a variant is set")
eq(b._attrs.macrotext,
    "/cleartarget\n/targetexact Pygmy Surf Crawler\n/cleartarget [dead]\n/targetexact Pygmy Surf Crawler",
    "...with the name in every line")
eq(b._attrs.macrotext2, "/cleartarget\n/targetexact Pygmy Surf Crawler\n/tm 8", "right-click unchanged")
eq(T.aim("Pygmy Surf Crawler", 3106, "8"), true, "no variant")
eq(b._attrs.macrotext, "/cleartarget\n/targetexact Pygmy Surf Crawler", "...is the default macro")

-- The list layout mockups (#88): plain frames, never secure.
do
    local H = T.hud
    eq(H.shortProgress({ "Big Game: 3/10 Stranglethorn Tiger slain" }), "3/10", "progress: the count")
    eq(H.shortProgress({ "Welcome: ready to turn in" }), "turn in", "...or the turn-in")
    local layout, look, n = H.show("compact", "forever", false)
    eq(layout .. " " .. look .. " " .. n, "compact forever 0", "nothing on Stakeout's frame: no rows")
    layout, look, n = H.show("wide", "forever", true)
    eq(n, 11, "the demo's eleven rows")
    local f = H.frame()
    check(f:IsShown() and not f._template:find("Secure", 1, true), "a plain frame, shown")
    local tiger = H.rows()["Stranglethorn Tiger"]
    eq(tiger.progress:GetText(), "4/10", "a row's progress")
    eq(H.rows()["Jungle Stalker"].progress:GetText(), "1/10", "a hunted row keeps its progress")
    H.show("compact", "glass", true)
    check(H.rows()["Stranglethorn Tiger"] ~= tiger, "a new look: new rows")
    H.hide()
    eq(f:IsShown(), false, "hidden")
    SlashCmdList.FOREVERPROBE("so hud wide")
    eq(f:IsShown(), true, "/fp so hud wide shows it")
    SlashCmdList.FOREVERPROBE("so hud off")
    eq(f:IsShown(), false, "/fp so hud off hides it")
    -- No row or group header overlaps another, in either layout (Codex: a
    -- full line at a group's end was overlapped by the next header).
    local function overlaps(layout)
        H.show(layout, "forever", true)
        local fr, boxes = H.frame(), {}
        local rowH = layout == "wide" and 34 or 22
        for _, row in pairs(H.rows()) do
            if row:IsShown() then
                local p = row._points[#row._points]
                boxes[#boxes + 1] = { x = p[4], top = -p[5], bottom = -p[5] + rowH }
            end
        end
        for _, h in ipairs(fr.headers) do
            if h:IsShown() then
                local p = h._points[#h._points]
                boxes[#boxes + 1] = { x = nil, top = -p[5], bottom = -p[5] + 12 }
            end
        end
        local bad = 0
        for i = 1, #boxes do
            for j = i + 1, #boxes do
                local a, c = boxes[i], boxes[j]
                local sameColumn = a.x == nil or c.x == nil or a.x == c.x
                if sameColumn and a.top < c.bottom and c.top < a.bottom then bad = bad + 1 end
            end
        end
        return bad, #boxes
    end
    local bad, boxes = overlaps("compact")
    eq(bad, 0, "compact: nothing overlaps (" .. boxes .. " rows and headers)")
    bad, boxes = overlaps("wide")
    eq(bad, 0, "wide: nothing overlaps, a full line before a new group included (" .. boxes .. ")")

    -- Glass, then Forever again: a frame per look, so no glass is left on Forever's.
    H.show("compact", "glass", true)
    local glassFrame = H.frame()
    H.show("compact", "forever", true)
    check(H.frame() ~= glassFrame and H.frame():IsShown() and not glassFrame:IsShown(),
        "back to Forever: its own frame, the glass one hidden")
    H.show("compact", "glass", true)
    eq(H.frame(), glassFrame, "...and Glass again reuses the glass one")
    -- Forever -> Glass -> Forever: each frame stands against UIParent, never
    -- against the other look's frame (Codex on #91: a circular anchor).
    H.show("compact", "forever", true)
    local foreverFrame = H.frame()
    local function anchoredTo(f, other)
        for _, p in ipairs(f._points or {}) do if p[2] == other then return true end end
        return false
    end
    check(not anchoredTo(foreverFrame, glassFrame) and not anchoredTo(glassFrame, foreverFrame),
        "a look round trip leaves neither frame anchored to the other")
    H.hide()

    -- A rejected Read face throws, so the procedure stays on that step; the
    -- command form just returns the reason (Codex on #91).
    WoW.units = {}
    local okStep, whyStep = pcall(H.startFaceStep)
    check(not okStep and tostring(whyStep):find("no target", 1, true), "a rejected read keeps the step: " .. tostring(whyStep))
    eq(H.faceDrawn(), false, "...and nothing counts as drawn")

    -- Stakeout still showing a face the mockup missed: a boolean from either
    -- representation (#90's btn.portrait, or main's btn.portraitOf).
    WoW.allowGlobal("StakeoutBtn1")
    WoW.allowGlobal("StakeoutBtn2")
    local b1 = CreateFrame("Button", "StakeoutBtn1", UIParent)
    b1.npcName, b1.portrait = "Face Kept", {}
    b1.label = b1:CreateFontString()
    b1.icon = b1:CreateTexture()
    local b2 = CreateFrame("Button", "StakeoutBtn2", UIParent)
    b2.npcName, b2.portraitOf = "Old Face", "Old Face"
    b2.label = b2:CreateFontString()
    b2.icon = b2:CreateTexture()
    _G.StakeoutBtn1, _G.StakeoutBtn2 = b1, b2
    local rows = H.stakeoutRows()
    eq(rows[1] and rows[1].stakeoutFace, true, "#90's cache: true")
    eq(rows[2] and rows[2].stakeoutFace, true, "main's portraitOf: true")
    b2.portraitOf = "Someone Else"
    eq(H.stakeoutRows()[2].stakeoutFace, false, "a face of another name: false, never a texture")
    _G.StakeoutBtn1, _G.StakeoutBtn2 = nil, nil

    local ok, why = H.startFace()
    eq(ok, false, "the face test needs a target: " .. tostring(why))
    eq(H.pollFace(), false, "...and polls nothing before Read face")

    -- Through ForeverProbe's runner: a face that is never drawn (the display
    -- ID stays 0, run #497) ends the wait by timeout or by Done, and neither
    -- can give a yes/no match: the comparison is a note step whose check
    -- FAILs without a draw (Codex on #91).
    local S = FP.Steps
    local take, nowFn = FP.Screenshots.Take, S.Now
    FP.Screenshots.Take = function(_, _, cb) if cb then cb(nil) end end
    local function faceRun(endWait)
        WoW.SetUnit("target", { name = "Kurzen Jungle Fighter", guid = "Creature-0-0-0-0-937-1" })
        fp("steps so face")
        local rec = FP.db.steps.records["StakeoutProbe/face"]
        S.Run()
        eq(rec.at, 2, "Read face on a living target moves on to the wait")
        endWait()
        eq(rec.at, 3, "the wait ended")
        S.Next()
        local r = rec.results[3]
        check(r.status ~= "yes" and r.status ~= "no", "no match answer is possible: " .. tostring(r.status))
        eq(r.check, "FAIL", "the comparison's check fails without a draw")
        fp("steps stop")
        return rec
    end
    local rec = faceRun(function()
        local t0 = S.Now()
        S.Now = function() return t0 + 16 end
        S.Poll()
        S.Now = nowFn
    end)
    eq(rec.results[2].status, "timeout", "the first run timed out")
    rec = faceRun(function() S.DoneByHand() end)
    eq(rec.results[2].check, "FAIL", "Done by hand without a draw: the wait's check fails")
    FP.Screenshots.Take = take
    WoW.units = {}
end

local errors = 0
for _, l in ipairs(db.log) do if l:find("ERROR") then errors = errors + 1 end end
eq(errors, 0, "nothing threw")
eq(#WoW.chat, 0, "nothing in chat")

done("test_probe")
