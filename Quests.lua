-------------------------------------------------------------------------------
-- Stakeout — quest targets (#24)
--
-- Buttons for what the quest log wants: the mobs to kill or loot, and the NPC
-- to turn a finished quest in to. Loads after Stakeout.lua and plugs into its
-- hooks (ns.core); the core renders what ButtonSpecs returns, after the watch
-- list's own buttons. What the client gives this is measured in
-- docs/FOREVER-PROBE.md, section 12.
--
-- Two sources:
--   * The quest log, always. Without anything else this is a reduced subset: a
--     unit you see whose name appears in an unfinished kill objective gets a
--     button. No turn-in buttons, no item droppers.
--   * A data provider, ns.questData, when one is set (QuestieData.lua reads
--     QuestieDB). It knows each objective's NPCs, the droppers of an item, who
--     ends a quest and where an NPC stands. Its interface is described below.
-------------------------------------------------------------------------------
local _, ns = ...
local C = ns.core

local fmt              = string.format
local tinsert, tsort   = table.insert, table.sort
local GetTime          = GetTime

local LINGER    = C.LINGER   -- the watch list's: seconds a target stays after it was last seen
local QUEST_MAX = 8          -- quest buttons at most; the watch list's are outside this
local REBUILD_DELAY = 0.2    -- quest events come in bursts (FOREVER-PROBE.md, `events`)

-- The tiers a target can be in. NEAR is "the player is near a known spawn",
-- from the provider's Spawns, for the NPCs to turn in to or talk to. HUNT
-- (#81, opt-in) is a mob the quests still want with a known spawn within a
-- click's reach (NEAR_IN / NEAR_OUT), not seen yet: the button is there to be
-- clicked until it finds one. It only fills the slots the others leave.
local VISIBLE, LINGERING, NEAR, HUNT, NONE = 3, 2, 1, 0.5, 0
local TIERS = { VISIBLE, LINGERING, NEAR, HUNT }   -- the selection's order

-- Yards. An NPC is near within NEAR_IN of one of its spawns and stays near
-- until NEAR_OUT, so standing at the edge doesn't flicker the button. A click
-- reaches a friendly NPC with no nameplate at 100 yd and more (FOREVER-PROBE.md,
-- `range`). Mobs get no NEAR: reaching a live hostile with no plate is unmeasured.
-- HUNT (opt-in) uses the same radius: a mob whose spawns are all farther than a
-- click reaches gets no button (a map-wide hunt filled every slot with mobs
-- out of reach).
local NEAR_IN, NEAR_OUT = 80, 100

-- Raid markers for the right-click /tm: skull, cross, square for mobs; star,
-- circle for NPCs. The watch list's own marker is skipped.
local MOB_MARKS      = { 8, 7, 6 }
local FRIENDLY_MARKS = { 1, 2 }

-------------------------------------------------------------------------------
-- The data provider
--
-- ns.questData is a table of plain functions (called with a dot, no self),
-- every one optional. Each call is wrapped in pcall, and a bad answer counts
-- as no answer.
--
--   Objectives(questID) -> entries, or nil when the provider doesn't know the
--       quest (the quest is then read as if there were no provider). Entries
--       are in the provider's objective order, with its ordering hints
--       (QuestieDB's ObjectiveFirst) already applied. Each entry is
--         { kind = "creature" | "killcredit" | "item" | "object",
--           id   = number,   -- NPC, kill-credit root NPC, item or object ID
--           name = string,   -- what the quest log row says (creature, item or
--                            -- object name; a kill credit's root text); optional
--           ids  = { npcId, ... } }  -- killcredit only: the NPCs that give it
--       One malformed entry makes the whole list unusable: dropping it would
--       shift the order the association falls back on.
--   ItemDroppers(itemID)  -> { npcId, ... }: the NPCs that drop it (may be empty)
--   NpcName(npcID)        -> string: the NPC's name, for /targetexact until the
--                            unit is seen (the observed name wins then)
--   FinishedBy(questID)   -> { npcId, ... }: who the quest is turned in to
--   Spawns(npcID)         -> { [uiMapID] = { { x, y }, ... } }: where the NPC
--                            stands, x and y in 0..1 of that map (for NEAR)
-------------------------------------------------------------------------------
local function Ask(method, ...)
    local provider = ns.questData
    if type(provider) ~= "table" or type(provider[method]) ~= "function" then return nil end
    local ok, answer = pcall(provider[method], ...)
    if ok then return answer end
    return nil
end

local function HasProvider()
    return type(ns.questData) == "table"
end

-- A list of positive integers, or an empty one.
local function IdList(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, id in ipairs(list) do
        if type(id) == "number" and id > 0 then out[#out + 1] = id end
    end
    return out
end

local function PlainString(v)
    return type(v) == "string" and not C.IsSecret(v) and v ~= "" and v or nil
end

-- Which quest log row type each kind of entry can be.
local ROW_TYPE = { creature = "monster", killcredit = "monster", item = "item", object = "object" }

local function ProviderEntries(questID)
    if not HasProvider() then return nil end
    local list = Ask("Objectives", questID)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, e in ipairs(list) do
        if type(e) ~= "table" or not ROW_TYPE[e.kind] or type(e.id) ~= "number" then return nil end
        local entry = { kind = e.kind, id = e.id, name = PlainString(e.name) }
        if e.kind == "killcredit" then
            entry.ids = IdList(e.ids)
            if #entry.ids == 0 then entry.ids = { e.id } end
        end
        out[i] = entry
    end
    return out
end

-------------------------------------------------------------------------------
-- Objective association
--
-- Which live quest log row each provider entry is, so its progress can be read.
-- The same ordered list Questie builds, matched in four steps:
--   1. The entries come in the provider's order (ObjectiveFirst applied there).
--   2. By text: an entry takes a row whose text contains its name literally,
--      of a compatible type (creature and kill credit -> "monster", item ->
--      "item", object -> "object"), only when that is the entry's one candidate
--      row and no other entry has that row as its one candidate too. A row is
--      taken once. Repeated until nothing more matches, since one match can
--      settle another ("Pygmy Surf Crawler" takes its row, and "Crawler" is
--      left with one).
--   3. By order: the entries left of one type pair with the rows left of that
--      type, in order, only when there are as many of each.
--   4. Anything left is "progress unknown": unfinished until the quest is
--      complete. A guess is never used, because a wrong one could hide a target
--      still wanted.
-- A creature left over when no monster row is left is someone to talk to, not
-- to kill (Forever's objective type 14, "Learn cooking from Cook Torka", is a
-- row of type "object"; FOREVER-PROBE.md, `quests`).
--
-- Returns, per entry, { row = index or nil, talk = true or nil }.
-------------------------------------------------------------------------------
local function Contains(row, name)
    return type(row.text) == "string" and row.text:find(name, 1, true) ~= nil
end

local function Associate(entries, rows)
    local rowOf, taken = {}, {}

    -- Each pass: every unassigned entry's candidate rows. One with a single
    -- candidate takes it, unless another entry has that same row as its only
    -- candidate too (two claims on one row: neither is sure).
    local changed = true
    while changed do
        changed = false
        local only = {}   -- [entry] = its one candidate row
        local claims = {} -- [row] = how many entries have it as their one candidate
        for i, e in ipairs(entries) do
            if not rowOf[i] and e.name then
                local hit, count = nil, 0
                for r, row in ipairs(rows) do
                    if not taken[r] and row.type == ROW_TYPE[e.kind] and Contains(row, e.name) then
                        hit, count = r, count + 1
                    end
                end
                if count == 1 then
                    only[i] = hit
                    claims[hit] = (claims[hit] or 0) + 1
                end
            end
        end
        for i in ipairs(entries) do
            local r = only[i]
            if r and claims[r] == 1 then
                rowOf[i], taken[r] = r, true
                changed = true
            end
        end
    end

    for _, want in ipairs({ "monster", "item", "object" }) do
        local es, rs = {}, {}
        for i, e in ipairs(entries) do
            if not rowOf[i] and ROW_TYPE[e.kind] == want then es[#es + 1] = i end
        end
        for r, row in ipairs(rows) do
            if not taken[r] and row.type == want then rs[#rs + 1] = r end
        end
        if #es > 0 and #es == #rs then
            for k = 1, #es do rowOf[es[k]], taken[rs[k]] = rs[k], true end
        end
    end

    local monsterLeft = false
    for r, row in ipairs(rows) do
        if not taken[r] and row.type == "monster" then monsterLeft = true end
    end
    local out = {}
    for i, e in ipairs(entries) do
        out[i] = { row = rowOf[i], talk = (not rowOf[i] and e.kind == "creature" and not monsterLeft) or nil }
    end
    return out
end

-------------------------------------------------------------------------------
-- The model
--
-- An ObjRef is one thing a quest wants: { questID, objKey, kind, index, ... }.
--   kind:   "kill", "item", "turnin", "talk" or "object" (no button: not a unit)
--   objKey: stable across rebuilds: "c<npcId>" a creature, "k<rootId>" a kill
--           credit, "i<itemId>" an item, "o<objectId>" an object, "t" the
--           turn-in, "n:<name>" when only a seen unit's name is known
--   index:  the live quest log row it reads its progress from, or nil
--           ("progress unknown")
-- A Member is one NPC ID (or one name, with no ID) and the refs it serves, with
-- its sighting state: { npcId, dbName, observed, refs, tokens, guids,
-- lastSeen, near, dist, spawns }. dist is the yards to its nearest known spawn
-- on the player's map, while it is wanted near (turn-in, talk). tokens are the unit tokens showing it now
-- (plates, target, mouseover) -> its GUID or true.
-- A NameTarget (built in ButtonSpecs) is every member that shares one
-- /targetexact name: one button, one place under the cap.
-------------------------------------------------------------------------------
local members  = {}   -- [key] = Member: "id:<npcId>", "n:<name>" (no provider), "o:<name>" (other)
local byName   = {}   -- [provider name] = { Member, ... }: for a unit whose GUID isn't readable
local holders  = {}   -- [token] = { [Member] = true }
local questList = {}  -- the last read of the log: { questID, title, complete, rows, refs, pos }
local nameRows = {}   -- unfinished monster rows of quests no provider knows: the name rule
local dirty    = false

local loggedIn, logReady = false, false   -- PLAYER_LOGIN, then a QUEST_LOG_UPDATE after it
local rebuildPending = false
local lastShown = {}  -- [name] = its place in the last ButtonSpecs: incumbents keep their slot
-- #94: armed alerts (the Alerts section below); Hold reaches them first.
local alerts = {}     -- { rec, ... }
local NoteAlertName   -- Hold's hook, defined with the alerts
local CheckAlerts, ReconcileAlerts   -- Rebuild's, defined with them too
local suspendAlerts = false   -- while Rebuild rescans: one check at its end
local suspendedWatch = {}     -- what the watch list announced meanwhile

-- Experimental, and off until the player turns it on (/stakeout quests on).
local function Enabled()
    return StakeoutDB ~= nil and StakeoutDB.questTargets == true
end

local function OtherEnabled()
    return StakeoutDB ~= nil and StakeoutDB.questOther == true
end

-- Hunt mode (#81): mobs get a button before they're seen. Off by default.
local function HuntEnabled()
    return StakeoutDB ~= nil and StakeoutDB.questHunt == true
end

-- The NPC ID of a plain creature GUID ("Creature-0-<server>-<instance>-<zone>-<id>-<spawn>").
local function NpcIdFromGuid(guid)
    if type(guid) ~= "string" or C.IsSecret(guid) then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
    return nil
end

local function NameOf(m)
    return m.observed or m.dbName
end

local function Tier(m, now)
    if next(m.tokens) then return VISIBLE end
    if m.lastSeen and now - m.lastSeen <= LINGER then return LINGERING end
    if m.near then return NEAR end
    if m.hunt then return HUNT end
    return NONE
end

-- Note a member's tier; a change means the buttons may change.
local function Touch(m)
    local tier = Tier(m, GetTime())
    if tier ~= m.tier then
        m.tier = tier
        dirty = true
    end
end

local function Flush()
    if dirty then
        dirty = false
        C.RequestFrameRefresh()
    end
end

local function NewMember(key, npcId)
    return { key = key, npcId = npcId, refs = {}, tokens = {}, guids = {}, near = false, tier = NONE }
end

-- Each GUID of a sighting lives as long as that unit's own part of it (Codex
-- on #45): `true` while a token shows it, then the time it left sight, and
-- gone LINGER seconds after that (Tick). So a death while it lingers still
-- ends it at once, and an old one never keeps a later one's sighting alive.
local function Depart(m, guid)
    if type(guid) ~= "string" or not m.guids[guid] then return end
    for _, g in pairs(m.tokens) do
        if g == guid then return end   -- another token still shows it
    end
    m.guids[guid] = GetTime()
end

local function Hold(m, token, guid, name)
    -- A token now showing another unit of the member (a plate reused without
    -- a removal): the one it showed before has left sight.
    local before = m.tokens[token]
    m.tokens[token] = guid or true
    if before ~= m.tokens[token] then Depart(m, before) end
    holders[token] = holders[token] or {}
    holders[token][m] = true
    if guid then m.guids[guid] = true end
    -- An armed alert follows the member through a new spelling: checked by
    -- the name it had until now (#94).
    NoteAlertName(m, name)
    m.observed = name
    m.unit = token
    m.lastSeen = GetTime()
    -- Its face, while this token shows it (Stakeout.lua's CacheFace).
    if name and type(C.CacheFace) == "function" then C.CacheFace(name, token) end
    Touch(m)
end

-- The token stopped showing the member. It was seen until now: it lingers.
local function Release(m, token)
    local guid = m.tokens[token]
    m.tokens[token] = nil
    Depart(m, guid)
    if holders[token] then holders[token][m] = nil end
    if m.unit == token then m.unit = nil end
    if not next(m.tokens) then m.lastSeen = GetTime() end
    Touch(m)
end

local function Forget(m)
    for token in pairs(m.tokens) do
        if holders[token] then holders[token][m] = nil end
    end
    members[m.key] = nil
    dirty = true
end

-- The sighting is over. Members that exist only because they were seen (a
-- name match, another quest unit) go with it.
local function EndSighting(m)
    for token in pairs(m.tokens) do
        if holders[token] then holders[token][m] = nil end
    end
    m.tokens, m.guids, m.lastSeen, m.unit = {}, {}, nil, nil
    if m.seenOnly then Forget(m) else Touch(m) end
end

-- Whether this name/GUID, read from a token, is the member.
local function Shows(m, name, guid)
    if name == nil then return false end
    local id = NpcIdFromGuid(guid)
    if m.npcId and id then return id == m.npcId end
    return name == NameOf(m) or name == m.dbName
end

-------------------------------------------------------------------------------
-- Near: the player's distance to a known spawn of an NPC to turn in to or talk
-- to (FOREVER-PROBE.md, `quests` P3: map position times the map's size in
-- yards matches the world distance).
-------------------------------------------------------------------------------
-- Where the player is: { map, x, y, w, h } (x, y in 0..1; w, h in yards), or
-- nil (no map, an instance, anything unreadable).
local function PlayerPosition()
    local ok, pos = pcall(function()
        local map = C_Map.GetBestMapForUnit("player")
        if type(map) ~= "number" or C.IsSecret(map) then return nil end
        local v = C_Map.GetPlayerMapPosition(map, "player")
        if not v or C.IsSecret(v) then return nil end
        local x, y = v:GetXY()
        local w, h = C_Map.GetMapWorldSize(map)
        for _, n in ipairs({ x, y, w, h }) do
            if type(n) ~= "number" or C.IsSecret(n) then return nil end
        end
        if w <= 0 or h <= 0 then return nil end
        return { map = map, x = x, y = y, w = w, h = h }
    end)
    return ok and pos or nil
end

-- Whether a member is someone to find by their spawn: an NPC to turn a quest
-- in to, or to talk to, that a quest still wants.
local function WantsNear(m)
    if not m.npcId then return false end
    for _, ref in ipairs(m.refs) do
        if ref.eligible and (ref.kind == "turnin" or ref.kind == "talk") then return true end
    end
    return false
end

-- Whether a member is a mob to hunt by its spawn (#81): a kill or a dropper
-- an unfinished objective still wants, with a name to /targetexact.
local function WantsHunt(m)
    if not (m.npcId and m.dbName and HuntEnabled()) then return false end
    for _, ref in ipairs(m.refs) do
        if ref.eligible and (ref.kind == "kill" or ref.kind == "item") then return true end
    end
    return false
end

local function UpdateNear(m, pos)
    local best
    local near, hunt = WantsNear(m), WantsHunt(m)
    if pos and (near or hunt) then
        if m.spawns == nil then
            local spawns = Ask("Spawns", m.npcId)
            m.spawns = type(spawns) == "table" and spawns or false
        end
        local points = m.spawns and m.spawns[pos.map]
        for _, pt in ipairs(type(points) == "table" and points or {}) do
            local sx, sy = type(pt) == "table" and pt[1], type(pt) == "table" and pt[2]
            if type(sx) == "number" and type(sy) == "number" then
                local d = math.sqrt(((pos.x - sx) * pos.w) ^ 2 + ((pos.y - sy) * pos.h) ^ 2)
                if not best or d < best then best = d end
            end
        end
    end
    m.dist = best
    m.near = near and best ~= nil and best <= (m.near and NEAR_OUT or NEAR_IN)
    -- Within a click's reach of a spawn, with the same in/out margin as NEAR
    -- so the edge doesn't flicker. The nearest spawn still ranks first
    -- (Prefer); the click finds out whether one is there now.
    m.hunt = hunt and best ~= nil and best <= (m.hunt and NEAR_OUT or NEAR_IN)
end

-- Every member's NEAR, from one read of the player's position (only when one
-- of them wants it). Touch only notices a tier change, but the selection also
-- ranks near members by distance (the reserved turn-in slot, Prefer): when the
-- order of the near ones changes, the buttons are picked again (Codex on #69).
local nearOrder = ""
local function UpdateAllNear()
    local pos
    for _, m in pairs(members) do
        if WantsNear(m) or WantsHunt(m) then
            pos = PlayerPosition()
            break
        end
    end
    local near = {}
    for _, m in pairs(members) do
        UpdateNear(m, pos)
        if m.near then near[#near + 1] = m end
    end
    tsort(near, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.key < b.key
    end)
    local keys = {}
    for i, m in ipairs(near) do keys[i] = m.key end
    local order = table.concat(keys, ",")
    if order ~= nearOrder then
        nearOrder = order
        dirty = true
    end
end

-------------------------------------------------------------------------------
-- Mutes. The keys are kept per ref and target, so muting one never hides
-- another. Writes go through the core's settings owner.
-------------------------------------------------------------------------------
local function QuestMuteKey(questID)
    return "q" .. questID
end

local function TargetMuteKey(ref, m)
    return fmt("q%d:%s:%s", ref.questID, ref.objKey, m.npcId and tostring(m.npcId) or (NameOf(m) or ""))
end

local function Muted(ref, m)
    local mutes = StakeoutDB and StakeoutDB.questMutes
    if type(mutes) ~= "table" then return false end
    return mutes[QuestMuteKey(ref.questID)] == true or mutes[TargetMuteKey(ref, m)] == true
end

-------------------------------------------------------------------------------
-- Reading the quest log
-------------------------------------------------------------------------------
-- One quest, read by its ID: its rows and whether it's complete.
local function ReadQuest(questID, title, pos)
    local rows = {}
    local raw = C_QuestLog.GetQuestObjectives(questID)
    if type(raw) == "table" then
        for r, o in ipairs(raw) do
            rows[r] = {
                text = PlainString(o.text), type = PlainString(o.type), finished = o.finished == true,
                numFulfilled = o.numFulfilled, numRequired = o.numRequired,
            }
        end
    end
    return {
        questID = questID, title = title, rows = rows,
        complete = C_QuestLog.IsComplete(questID) == true, pos = pos, refs = {},
    }
end

-- The second return says whether the read found every quest the log counts.
-- The first count is of the shown rows only, so a quest under a collapsed
-- header may be missing from a read: such a read must never prune its mutes.
local function ReadLogUnsafe()
    local n, total = C_QuestLog.GetNumQuestLogEntries()
    if type(n) ~= "number" then return nil end
    local list = {}
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if type(info) == "table" and not info.isHeader and type(info.questID) == "number" and info.questID > 0 then
            list[#list + 1] = ReadQuest(info.questID, PlainString(info.title), #list + 1)
        end
    end
    return list, type(total) == "number" and #list >= total
end

-- The quests in the log, or nil when it couldn't be read; then whether that
-- was all of them.
local function ReadLog()
    local ok, list, whole = pcall(ReadLogUnsafe)
    if ok then return list, whole end
    return nil
end

-- A quest a partial read missed (a collapsed header), read again by its ID:
-- fresh rows while the log still holds it, nil once it has left (turned in,
-- abandoned). Nil too when it can't be read.
local function RereadMissed(old, pos)
    local ok, quest = pcall(function()
        if not C_QuestLog.GetLogIndexForQuestID(old.questID) then return nil end
        return ReadQuest(old.questID, old.title, pos)
    end)
    return ok and quest or nil
end

-- A ref's progress. A row says it; without one the quest's completion does.
local function RefEligible(ref, quest)
    if ref.kind == "turnin" then return quest.complete end
    if ref.kind == "object" or ref.noSource then return false end
    if ref.index then
        local row = quest.rows[ref.index]
        return not (row and row.finished)
    end
    return not quest.complete
end

-------------------------------------------------------------------------------
-- The name rule (no provider for the quest): a seen unit whose name appears
-- literally in an unfinished monster row is wanted by it. No stripping of
-- " slain" or the like: that would be English-only.
-------------------------------------------------------------------------------
local function NameRefs(name)
    local refs = {}
    for _, nr in ipairs(nameRows) do
        if nr.text:find(name, 1, true) then
            refs[#refs + 1] = {
                questID = nr.questID, objKey = "n:" .. name, kind = "kill", index = nr.index,
                rank = nr.rank, eligible = true, quest = nr.quest,
            }
        end
    end
    return refs
end

-------------------------------------------------------------------------------
-- Rebuild: read the log, associate, and reconcile the members (a member that
-- survives keeps its sighting state; only the ones no quest wants go).
-------------------------------------------------------------------------------
local Rebuild   -- defined below; matching needs it only by name

-- Whether a unit would match a quest target (no side effects).
local function MatchesQuest(name, guid)
    local id = NpcIdFromGuid(guid)
    if id and members["id:" .. id] then return true end
    if byName[name] then return true end
    for _, nr in ipairs(nameRows) do
        if nr.text:find(name, 1, true) then return true end
    end
    return false
end

-- pcall'd reads of a unit: the result is tested inside, since a secret would
-- throw on the comparison.
local function Related(unit)
    local ok, related = pcall(function() return C_QuestLog.UnitIsRelatedToActiveQuest(unit) == true end)
    return ok and related
end

local function Attackable(unit)
    local ok, can = pcall(function() return UnitCanAttack("player", unit) == true end)
    return ok and can
end

local function ClearMembers()
    for _, m in pairs(members) do Forget(m) end
    wipe(byName)
    wipe(nameRows)
    wipe(questList)
    -- Quest targets off: no armed alert survives, and its marks go now, in
    -- combat too (region Show/Hide).
    if #alerts > 0 then
        wipe(alerts)
        C.RefreshAlertMarks()
    end
end

function Rebuild()
    rebuildPending = false
    if not Enabled() then
        ClearMembers()
        dirty = true
        Flush()
        return
    end
    local list, whole = ReadLog()
    if not list then return end   -- unreadable: keep what there is
    -- A partial read (a collapsed header hides quests) keeps the quests it
    -- missed, so their targets and sightings stay: each is read again by its
    -- ID, so its progress stays current and it goes once it leaves the log
    -- (Codex on #45).
    if not whole then
        local present = {}
        for _, quest in ipairs(list) do present[quest.questID] = true end
        for _, old in ipairs(questList) do
            if not present[old.questID] then
                local quest = RereadMissed(old, #list + 1)
                if quest then list[#list + 1] = quest end
            end
        end
    end

    local wanted = {}   -- [key] = { npcId, dbName, refs }
    local function want(key, npcId, dbName, ref)
        local w = wanted[key]
        if not w then
            w = { npcId = npcId, refs = {} }
            wanted[key] = w
        end
        w.dbName = w.dbName or PlainString(dbName)
        if ref then w.refs[#w.refs + 1] = ref end
    end

    local newNameRows = {}
    for _, quest in ipairs(list) do
        local base = quest.pos * 1000
        local entries = ProviderEntries(quest.questID)
        if entries then
            local assoc = Associate(entries, quest.rows)
            for i, e in ipairs(entries) do
                local a = assoc[i]
                local ref = { questID = quest.questID, index = a.row, rank = base + i, quest = quest }
                if e.kind == "creature" then
                    ref.objKey, ref.kind = "c" .. e.id, a.talk and "talk" or "kill"
                    want("id:" .. e.id, e.id, e.name or Ask("NpcName", e.id), ref)
                elseif e.kind == "killcredit" then
                    ref.objKey, ref.kind = "k" .. e.id, "kill"
                    for _, id in ipairs(e.ids) do want("id:" .. id, id, Ask("NpcName", id), ref) end
                elseif e.kind == "item" then
                    ref.objKey, ref.kind = "i" .. e.id, "item"
                    local droppers = IdList(Ask("ItemDroppers", e.id))
                    -- Most of Forever's own items have no known dropper: no button.
                    if #droppers == 0 then ref.noSource = true end
                    for _, id in ipairs(droppers) do want("id:" .. id, id, Ask("NpcName", id), ref) end
                else
                    ref.objKey, ref.kind = "o" .. e.id, "object"
                end
                quest.refs[#quest.refs + 1] = ref
            end
            local turnin = { questID = quest.questID, objKey = "t", kind = "turnin", rank = base + 999, quest = quest }
            quest.refs[#quest.refs + 1] = turnin
            for _, id in ipairs(IdList(Ask("FinishedBy", quest.questID))) do
                want("id:" .. id, id, Ask("NpcName", id), turnin)
            end
        else
            for r, row in ipairs(quest.rows) do
                if row.type == "monster" and not row.finished and row.text then
                    newNameRows[#newNameRows + 1] = {
                        questID = quest.questID, index = r, text = row.text, rank = base + 500 + r, quest = quest,
                    }
                end
            end
        end
        for _, ref in ipairs(quest.refs) do ref.eligible = RefEligible(ref, quest) end
    end

    questList = list
    nameRows = newNameRows
    wipe(byName)
    for key, w in pairs(wanted) do
        local m = members[key] or NewMember(key, w.npcId)
        members[key] = m
        m.dbName, m.refs, m.spawns = w.dbName, w.refs, nil
        if m.dbName then
            byName[m.dbName] = byName[m.dbName] or {}
            tinsert(byName[m.dbName], m)
        end
        dirty = true
    end
    for key, m in pairs(members) do
        if key:sub(1, 3) == "id:" and not wanted[key] then
            Forget(m)
        elseif key:sub(1, 2) == "n:" then
            -- A name match is re-read against the new rows.
            m.refs = NameRefs(NameOf(m))
            if #m.refs == 0 then Forget(m) else dirty = true end
        elseif key:sub(1, 2) == "o:" then
            -- Another quest unit is kept only if a token still shows it, the
            -- client still relates it to a quest, and nothing better matches.
            local keep = false
            if OtherEnabled() then
                for token in pairs(m.tokens) do
                    local name, guid = C.ReadNPC(token)
                    if name == NameOf(m) and not MatchesQuest(name, guid) and Related(token) then
                        keep = true
                        break
                    end
                end
            end
            if not keep then Forget(m) end
        end
    end

    if loggedIn and logReady and whole then
        local active = {}
        for _, quest in ipairs(list) do active[quest.questID] = true end
        C.PruneQuestMutes(active)
    end

    -- A turn-in just completed, near its NPC, shows now rather than at the tick.
    UpdateAllNear()
    for _, m in pairs(members) do m.tier = Tier(m, GetTime()) end

    -- Armed alerts take the members they now cover, or go (#94).
    ReconcileAlerts()

    -- Units already on screen match the new set now, not at their next event.
    -- The core's watch state is untouched, so a watched unit doesn't alert again.
    -- The alerts are checked once, after the whole rescan: a member forgotten
    -- above and held again by it never reads as a departure.
    suspendAlerts = true
    C.Rescan()
    suspendAlerts = false
    local watched = suspendedWatch
    suspendedWatch = {}
    CheckAlerts(nil, watched)
    dirty = true
    Flush()
end

local function ScheduleRebuild()
    if rebuildPending then return end
    rebuildPending = true
    C_Timer.After(REBUILD_DELAY, Rebuild)
end

-------------------------------------------------------------------------------
-- Alerts (#94). Shift+right-click on a quest button arms an alert for its
-- target. It plays (the core's Announce: chat, flash, sound) when one appears
-- on a NAMEPLATE: about 40 yd, a live unit (ReadNPC reads no dead one), one the
-- button's /targetexact finds. Target and mouseover alone don't count: you're
-- already looking at it. As the watch list does, a unit leaving plate range
-- keeps it quiet for REARM seconds, so a plate flickering at the edge alerts
-- once; the death of the one that left last re-arms it at once, for the
-- respawn.
--
-- A record covers its target's members by key and by their current name. A
-- hunt button's provider name can turn into the observed spelling on the
-- first plate; Hold carries the member over before it renames it. Designed
-- with Codex over six rounds (#94's plan).
--
-- rec = { keys = { [memberKey] = true }, names = { [name] = true },
--         plated, guids (the plain GUIDs on its plates at the last check),
--         quietUntil, departGuid (the one whose plate went last), other }
-------------------------------------------------------------------------------

local function IsPlateToken(token)
    return type(token) == "string" and token:find("^nameplate") ~= nil
end

local function Covers(rec, m)
    if rec.keys[m.key] then return true end
    local name = NameOf(m)
    return name ~= nil and rec.names[name] == true
end

-- Whether a plate shows one of the record's members now, the plain GUIDs on
-- those plates, and the name one of them shows (for the chat line).
local function PlatePresence(rec)
    local any, guids, shown = false, {}, nil
    for _, m in pairs(members) do
        if Covers(rec, m) then
            for token, g in pairs(m.tokens) do
                if IsPlateToken(token) then
                    any = true
                    shown = shown or NameOf(m)
                    if type(g) == "string" then guids[g] = true end
                end
            end
        end
    end
    return any, guids, shown
end

local function FindAlert(name)
    for _, rec in ipairs(alerts) do
        if rec.names[name] then return rec end
    end
end

-- Records that came to share a name or a key become one (two armed hunt
-- buttons whose first plates show one spelling): one alert, one toggle.
local function MergeAlerts()
    local i = 1
    while i <= #alerts do
        local a, j = alerts[i], i + 1
        while j <= #alerts do
            local b, shared = alerts[j], false
            for k in pairs(b.keys) do
                if a.keys[k] then shared = true break end
            end
            if not shared then
                for n in pairs(b.names) do
                    if a.names[n] then shared = true break end
                end
            end
            if shared then
                for k in pairs(b.keys) do a.keys[k] = true end
                for n in pairs(b.names) do a.names[n] = true end
                for g in pairs(b.guids) do a.guids[g] = true end
                a.plated = a.plated or b.plated
                if b.quietUntil > a.quietUntil then a.quietUntil, a.departGuid = b.quietUntil, b.departGuid end
                a.other = a.other and b.other
                table.remove(alerts, j)
            else
                j = j + 1
            end
        end
        i = i + 1
    end
end

-- Hold's hook, before it renames the member: a covered member's key and the
-- name it shows now join the record.
NoteAlertName = function(m, name)
    if #alerts == 0 then return end
    local touched = false
    for _, rec in ipairs(alerts) do
        if Covers(rec, m) then
            rec.keys[m.key] = true
            if name then rec.names[name] = true end
            touched = true
        end
    end
    if touched then MergeAlerts() end
end

-- Whether the quests still want the record's target: a member it covers with
-- an eligible ref, or a quest row naming one of its names (an "n:" member,
-- which a rebuild may have forgotten). Another quest unit ("o:", no ref, no
-- owning quest) is kept until it's toggled off or quest targets go off.
local function Wanted(rec)
    if rec.other then return true end
    for _, m in pairs(members) do
        if Covers(rec, m) then
            for _, ref in ipairs(m.refs) do
                if ref.eligible then return true end
            end
        end
    end
    for n in pairs(rec.names) do
        if #NameRefs(n) > 0 then return true end
    end
    return false
end

-- After every event that can change a plate: arrivals and departures.
-- diedGuid: the unit UNIT_DIED named. watchNames: the names the watch list
-- just announced for this sighting, which don't announce twice.
CheckAlerts = function(diedGuid, watchNames)
    if #alerts == 0 then return end
    if suspendAlerts then
        for n in pairs(watchNames or {}) do suspendedWatch[n] = true end
        return
    end
    local now = GetTime()
    for _, rec in ipairs(alerts) do
        local plated, guids, shown = PlatePresence(rec)
        if plated and not rec.plated then
            rec.departGuid = nil
            local announced = false
            for n in pairs(watchNames or {}) do
                if rec.names[n] then announced = true end
            end
            if now >= rec.quietUntil and not announced then C.Announce(shown) end
        elseif not plated and rec.plated then
            -- Which unit's plate went last: only knowable when one went.
            -- Several at once (a tick finding two gone) keeps the quiet.
            local only
            for g in pairs(rec.guids) do
                if only == nil then only = g else only = false break end
            end
            if only and diedGuid == only then
                rec.quietUntil, rec.departGuid = 0, nil
            else
                rec.quietUntil, rec.departGuid = now + C.REARM, only or nil
            end
        elseif not plated and diedGuid ~= nil and diedGuid == rec.departGuid then
            -- The one that left last died: its respawn alerts at once.
            rec.quietUntil, rec.departGuid = 0, nil
        end
        rec.plated, rec.guids = plated, guids
    end
end

-- Shift+right-click on a quest button (the core's PostClick): true when it
-- armed an alert, false when it turned one off, nil when the button is stale
-- (quest targets off, or the target no longer wanted; it can still be on
-- screen in combat). keys: the members of the button's target (its spec's
-- alertKeys).
local function ToggleAlert(name, keys)
    if not Enabled() or type(name) ~= "string" then return nil end
    local rec = FindAlert(name)
    if not rec and type(keys) == "table" then
        for _, r in ipairs(alerts) do
            for _, k in ipairs(keys) do
                if r.keys[k] then rec = r end
            end
        end
    end
    if rec then
        for i, r in ipairs(alerts) do
            if r == rec then
                table.remove(alerts, i)
                break
            end
        end
        return false
    end
    rec = { keys = {}, names = { [name] = true }, plated = false, guids = {}, quietUntil = 0 }
    for _, k in ipairs(type(keys) == "table" and keys or {}) do
        if type(k) == "string" then rec.keys[k] = true end
    end
    local hasRef, other = false, false
    for _, m in pairs(members) do
        if Covers(rec, m) then
            rec.keys[m.key] = true
            for _, ref in ipairs(m.refs) do
                if ref.eligible then hasRef = true end
            end
            if m.other then other = true end
        end
    end
    rec.other = other and not hasRef
    if not Wanted(rec) then return nil end
    -- One in view now doesn't alert: it has to leave and come back.
    rec.plated, rec.guids = PlatePresence(rec)
    alerts[#alerts + 1] = rec
    MergeAlerts()
    return true
end

local function AlertOn(name)
    return type(name) == "string" and FindAlert(name) ~= nil
end

-- Rebuild, before its rescan: each record takes the members it now covers,
-- and goes when the quests no longer want its target.
ReconcileAlerts = function()
    local dropped = false
    for i = #alerts, 1, -1 do
        local rec = alerts[i]
        for _, m in pairs(members) do
            if Covers(rec, m) then rec.keys[m.key] = true end
        end
        if not Wanted(rec) then
            table.remove(alerts, i)
            dropped = true
        end
    end
    MergeAlerts()
    if dropped then C.RefreshAlertMarks() end
end

-------------------------------------------------------------------------------
-- The core's hooks. Every unit the core reads comes here, watched or not,
-- with the name and GUID ReadNPC already read (nil when unreadable or secret).
-------------------------------------------------------------------------------
-- Matching, in order: the NPC ID from a plain GUID, then the observed name
-- against the provider's names, then the name rule; another quest unit only
-- when none of those matched.
local function Match(unit, name, guid)
    local found = {}
    local id = NpcIdFromGuid(guid)
    local m = id and members["id:" .. id]
    if m then
        found[m] = true
    elseif byName[name] then
        for _, bm in ipairs(byName[name]) do found[bm] = true end
    end
    local refs = NameRefs(name)
    if #refs > 0 then
        local key = "n:" .. name
        local nm = members[key]
        if not nm then
            nm = NewMember(key, nil)
            nm.seenOnly = true
            members[key] = nm
        end
        nm.refs = refs
        found[nm] = true
    end
    if not next(found) and OtherEnabled() and Related(unit) then
        local key = "o:" .. name
        local om = members[key]
        if not om then
            om = NewMember(key, nil)
            om.seenOnly, om.other = true, true
            members[key] = om
        end
        om.attackable = Attackable(unit)
        found[om] = true
    end
    return found
end

local function OnUnit(unit, isPlate, name, guid, watchAnnounced)
    if not Enabled() or type(unit) ~= "string" then return end
    if C.IsSecret(name) or type(name) ~= "string" then name = nil end
    if C.IsSecret(guid) or type(guid) ~= "string" then guid = nil end
    local found = name and Match(unit, name, guid) or {}
    -- The token shows this unit now, and no longer whoever it showed before.
    if holders[unit] then
        for m in pairs(holders[unit]) do
            if not found[m] then Release(m, unit) end
        end
    end
    for m in pairs(found) do Hold(m, unit, guid, name) end
    CheckAlerts(nil, watchAnnounced and name and { [name] = true } or nil)
    Flush()
end

local function OnPlateRemoved(token)
    if not Enabled() or type(token) ~= "string" or not holders[token] then return end
    for m in pairs(holders[token]) do Release(m, token) end
    CheckAlerts()
    Flush()
end

-- Departed GUIDs past their LINGER go (the tick, and before a death decides:
-- one expired between ticks must not keep the sighting alive, Codex on #45).
local function ExpireGuids(m, now)
    for guid, held in pairs(m.guids) do
        if type(held) == "number" and now - held > LINGER then m.guids[guid] = nil end
    end
end

local function OnUnitDied(guid)
    if not Enabled() or C.IsSecret(guid) or type(guid) ~= "string" then return end
    local now = GetTime()
    for _, m in pairs(members) do
        if m.guids[guid] then
            m.guids[guid] = nil
            ExpireGuids(m, now)
            for token, g in pairs(m.tokens) do
                if g == guid then
                    m.tokens[token] = nil
                    if holders[token] then holders[token][m] = nil end
                end
            end
            -- The one it was is dead: over at once. Another of the name that
            -- was seen too keeps it for now; the tick decides.
            if not next(m.tokens) and not next(m.guids) then
                EndSighting(m)
            else
                if not next(m.tokens) then m.lastSeen = GetTime() end
                Touch(m)
            end
        end
    end
    CheckAlerts(guid)
    Flush()
end

-- The 1 s tick: drop tokens that stopped showing a member (a missed plate
-- removal must not keep a button forever), keep the visible ones fresh, and
-- end sightings LINGER seconds after they were last seen.
local function Tick()
    if not Enabled() then return end
    local now = GetTime()
    UpdateAllNear()
    for _, m in pairs(members) do
        for token, held in pairs(m.tokens) do
            local name, guid = C.ReadNPC(token)
            if not Shows(m, name, guid) then
                Release(m, token)
            elseif type(guid) == "string" and not C.IsSecret(guid) and guid ~= held then
                -- The token shows another spawn of the member now (a plate
                -- reused without a removal): it holds the new GUID. Stored
                -- first, then the old one departs, as in Hold: Depart keeps a
                -- GUID any token still holds (#94, Codex). A late death of
                -- the old one then can't take this live plate away.
                m.tokens[token] = guid
                m.guids[guid] = true
                Depart(m, held)
            end
        end
        ExpireGuids(m, now)
        if next(m.tokens) then
            m.lastSeen = now
        elseif m.lastSeen and now - m.lastSeen > LINGER then
            EndSighting(m)
        end
        if members[m.key] == m then Touch(m) end
    end
    CheckAlerts()
    Flush()
end

-------------------------------------------------------------------------------
-- Selection: which targets get one of the QUEST_MAX buttons
--   1. One slot is reserved for a turn-in, only when an eligible one exists:
--      seen before near-only, then the nearest, then by name.
--   2. Tiers: visible > lingering > near > hunt (#81, opt-in). Kill and item
--      rank equally; other quest units come last in each tier.
--   3. Fairness: within a tier, a round-robin over objectives in quest log
--      order. A target several objectives share is picked once and serves
--      each of them. This can take a slot from an incumbent of the same tier
--      to give another objective one.
--   4. Stability: among an objective's targets the incumbents come first; when
--      a round has fewer slots than objectives, incumbents are served first;
--      and on the frame an incumbent keeps its place in its row.
-------------------------------------------------------------------------------
local function ObjectiveId(ref)
    return ref.questID .. ":" .. (ref.index and ("#" .. ref.index) or ref.objKey)
end

local function Incumbency(nt)
    return lastShown[nt.name] or math.huge
end

-- Within one objective, and for other quest units: incumbent, nearest, name.
local function Prefer(a, b)
    local ia, ib = Incumbency(a), Incumbency(b)
    if ia ~= ib then return ia < ib end
    local da, db = a.dist or math.huge, b.dist or math.huge
    if da ~= db then return da < db end
    return a.name < b.name
end

-- For the reserved turn-in: seen before near-only, nearest, then name.
local function BetterTurnin(a, b)
    if a.tier ~= b.tier then return a.tier > b.tier end
    local da, db = a.dist or math.huge, b.dist or math.huge
    if da ~= db then return da < db end
    return a.name < b.name
end

local function Select(candidates)
    local chosen, picked = {}, {}
    local function take(nt)
        picked[nt] = true
        chosen[#chosen + 1] = nt
    end

    local reserved
    for _, nt in ipairs(candidates) do
        if nt.turnin and (not reserved or BetterTurnin(nt, reserved)) then reserved = nt end
    end
    if reserved then take(reserved) end

    for _, tier in ipairs(TIERS) do
        if #chosen >= QUEST_MAX then break end
        local objectives, order, others = {}, {}, {}
        for _, nt in ipairs(candidates) do
            if nt.tier == tier then
                if nt.other then
                    if not picked[nt] then others[#others + 1] = nt end
                else
                    for _, ref in ipairs(nt.refs) do
                        local id = ObjectiveId(ref)
                        local o = objectives[id]
                        if not o then
                            o = { id = id, rank = ref.rank, list = {}, has = {} }
                            objectives[id] = o
                            order[#order + 1] = o
                        end
                        if not o.has[nt] then
                            o.has[nt] = true
                            o.list[#o.list + 1] = nt
                        end
                    end
                end
            end
        end
        tsort(order, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.id < b.id
        end)
        local longest = 0
        for _, o in ipairs(order) do
            tsort(o.list, Prefer)
            longest = math.max(longest, #o.list)
        end
        -- Round r: every objective with fewer than r of its targets picked
        -- (by itself or by another objective sharing them) gets its next one.
        -- When the slots left can't serve them all, incumbents go first, then
        -- the objective order.
        for round = 1, longest do
            local due = {}
            for _, o in ipairs(order) do
                local served, nextOne = 0, nil
                for _, nt in ipairs(o.list) do
                    if picked[nt] then served = served + 1 elseif not nextOne then nextOne = nt end
                end
                if served < round and nextOne then due[#due + 1] = { o = o, nt = nextOne, at = #due + 1 } end
            end
            tsort(due, function(x, y)
                local ix, iy = Incumbency(x.nt), Incumbency(y.nt)
                if ix ~= iy then return ix < iy end
                return x.at < y.at
            end)
            for _, d in ipairs(due) do
                if #chosen >= QUEST_MAX then break end
                -- Two objectives can share their next target: picked once.
                if not picked[d.nt] then take(d.nt) end
            end
        end
        tsort(others, Prefer)
        for _, nt in ipairs(others) do
            if #chosen >= QUEST_MAX then break end
            take(nt)
        end
    end
    return chosen
end

-------------------------------------------------------------------------------
-- ButtonSpecs: what the core renders after the watch list
-------------------------------------------------------------------------------
local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"

local function Progress(ref)
    local quest = ref.quest
    local title = quest and quest.title or ("Quest " .. ref.questID)
    if ref.kind == "turnin" then return title .. ": ready to turn in" end
    local row = ref.index and quest and quest.rows[ref.index]
    if row and row.text then return title .. ": " .. row.text end
    if ref.kind == "talk" then return title .. ": talk to them" end
    return title .. ": progress unknown"
end

-- A row's right side in the list layouts (#88): the count, "turn in" or
-- "talk"; nil when there's nothing short to say (a related unit, a row with
-- no plain count). The second return is the same count at its end, so the
-- core can make room for the widest it will come to ("10/10").
local function ShortProgress(ref)
    if not ref then return nil end
    if ref.kind == "turnin" then return "turn in" end
    if ref.kind == "talk" then return "talk" end
    if ref.kind ~= "kill" and ref.kind ~= "item" then return nil end
    local row = ref.index and ref.quest and ref.quest.rows[ref.index]
    local have, need = row and row.numFulfilled, row and row.numRequired
    if C.IsSecret(have) or C.IsSecret(need) or type(have) ~= "number" or type(need) ~= "number"
        or need <= 0 then
        return nil
    end
    return fmt("%d/%d", have, need), fmt("%d/%d", need, need)
end

-- Every target that could have a button now, one per /targetexact name.
local function CollectTargets(now)
    local byTarget, list = {}, {}
    for _, m in pairs(members) do
        local tier = Tier(m, now)
        local name = NameOf(m)
        if tier > NONE and C.MacroSafeName(name) and not C.IsWatchDisplayed(name) then
            local refs = {}
            for _, ref in ipairs(m.refs) do
                if ref.eligible and not Muted(ref, m) then refs[#refs + 1] = ref end
            end
            if #refs > 0 or m.other then
                local nt = byTarget[name]
                if not nt then
                    nt = { name = name, tier = NONE, refs = {}, hasRef = {}, ids = {}, members = {} }
                    byTarget[name] = nt
                    list[#list + 1] = nt
                end
                nt.members[#nt.members + 1] = m
                if m.npcId then nt.ids[#nt.ids + 1] = m.npcId end
                for _, ref in ipairs(refs) do
                    if not nt.hasRef[ref] then
                        nt.hasRef[ref] = true
                        nt.refs[#nt.refs + 1] = ref
                        if ref.kind == "kill" or ref.kind == "item" then nt.mob = true end
                        if ref.kind == "turnin" then nt.turnin = true end
                    end
                end
                if m.other and m.attackable then nt.otherMob = true end
                if tier > nt.tier or (tier == nt.tier and m.unit and not nt.unit) then
                    nt.tier, nt.unit = tier, m.unit
                end
                if m.dist and (not nt.dist or m.dist < nt.dist) then nt.dist = m.dist end
            end
        end
    end
    for _, nt in ipairs(list) do
        nt.other = #nt.refs == 0
        -- What the quest wants decides the row, never the unit's colour (a
        -- quest crawler is neutral until attacked). Mob wins over NPC.
        nt.row = (nt.mob or (nt.other and nt.otherMob)) and "enemy" or "friendly"
        tsort(nt.refs, function(a, b) return a.rank < b.rank end)
    end
    tsort(list, function(a, b) return a.name < b.name end)
    return list
end

-- The marker list for a row, without the watch list's own marker.
local function Marks(row)
    local out = {}
    for _, mark in ipairs(row == "enemy" and MOB_MARKS or FRIENDLY_MARKS) do
        if mark ~= StakeoutDB.markerIndex then out[#out + 1] = mark end
    end
    return out
end

local function ButtonSpecs()
    if not Enabled() then
        wipe(lastShown)
        return {}
    end
    local chosen = Select(CollectTargets(GetTime()))
    for i, nt in ipairs(chosen) do nt.picked = i end

    -- Incumbents first, in their old order, then the new ones as picked.
    tsort(chosen, function(a, b)
        local ia, ib = Incumbency(a), Incumbency(b)
        if ia ~= ib then return ia < ib end
        return a.picked < b.picked
    end)

    local specs, shown, count = {}, {}, { enemy = 0, friendly = 0 }
    for i, nt in ipairs(chosen) do
        shown[nt.name] = i
        local mob = nt.row == "enemy"
        -- /cleartarget [dead]: a mob button never ends on a corpse (the
        -- `corpse` probe). An NPC button doesn't need it.
        local left = mob and fmt("/cleartarget\n/targetexact %s\n/cleartarget [dead]", nt.name)
            or fmt("/cleartarget\n/targetexact %s", nt.name)
        local right
        local tooltip = {}
        for _, ref in ipairs(nt.refs) do tooltip[#tooltip + 1] = Progress(ref) end
        if nt.other then tooltip[#tooltip + 1] = "Related to one of your quests" end
        if nt.tier == HUNT then tooltip[#tooltip + 1] = "Not seen yet: click to look for one" end
        local mark
        if StakeoutDB.enableMarking then
            local marks = Marks(nt.row)
            count[nt.row] = count[nt.row] + 1
            mark = marks[(count[nt.row] - 1) % #marks + 1]
        end
        if mark then
            -- Left-click targets and marks, right-click only targets, as the
            -- watch list's do. !N keeps the mark on a second click; /tm N
            -- would take it off. [exists,nodead]: no mark (and no error)
            -- when the click finds no live one, as on a hunt button.
            right = left
            left = fmt("%s\n/tm [exists,nodead] !%d", left, mark)
            tooltip[#tooltip + 1] = "Left-click: target and mark"
            tooltip[#tooltip + 1] = "Right-click: target only"
        else
            tooltip[#tooltip + 1] = "Left-click: target"
        end
        -- The members' keys: what Shift+right-click arms (#94).
        local alertKeys = {}
        for _, m in ipairs(nt.members) do alertKeys[#alertKeys + 1] = m.key end
        -- The refs are ranked: the first one is what the row's right side says.
        local progress, progressMax = ShortProgress(nt.refs[1])
        specs[#specs + 1] = {
            row = nt.row, name = nt.name, macrotext = left, macrotext2 = right,
            unit = nt.unit, icon = QUEST_ICON, tooltip = tooltip,
            hunt = nt.tier == HUNT, progress = progress, progressMax = progressMax,
            alertKeys = alertKeys,
        }
    end
    lastShown = shown
    return specs
end

-------------------------------------------------------------------------------
-- Switches, mutes and events
-------------------------------------------------------------------------------
local function SetEnabled(on)
    C.SetConfig("questTargets", on and true or false)
    if on then
        ScheduleRebuild()
    else
        ClearMembers()
        dirty = true
        Flush()
    end
end

local function SetOther(on)
    C.SetConfig("questOther", on and true or false)
    ScheduleRebuild()
end

local function SetHunt(on)
    C.SetConfig("questHunt", on and true or false)
    ScheduleRebuild()
end

local function SetMute(key, on)
    if not C.SetQuestMute(key, on) then return false end
    dirty = true
    Flush()
    return true
end

local function PrintState()
    if not Enabled() then
        C.Print("Quest targets (experimental): |cffff6666off|r. |cff00ff00/stakeout quests on|r to try it.")
        if HuntEnabled() then
            C.Print("Hunt: |cff00ff00on|r, for when quest targets are on (it needs Questie's data).")
        end
        return
    end
    C.Print("Quest targets (experimental): |cff00ff00on|r, %d quests read. |cff00ff00/stakeout quests off|r " ..
        "turns them off.", #questList)
    if HasProvider() then
        C.Print("With Questie's data: objective mobs, item droppers, and the NPC to turn in to when you're near.")
    else
        C.Print("Without quest data (Questie), only mobs you see whose name is in a kill objective get a button.")
    end
    if HuntEnabled() then
        C.Print("Hunt: |cff00ff00on|r, quest mobs with a spawn within about 80 yards get a button before they're seen%s. " ..
            "|cff00ff00/stakeout quests hunt off|r turns it off.", HasProvider() and "" or " (needs Questie's data)")
    else
        C.Print("Hunt: off. |cff00ff00/stakeout quests hunt on|r shows quest mobs before they're seen, to click until " ..
            "one is found.")
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        loggedIn = true
    elseif event == "QUEST_LOG_UPDATE" and loggedIn then
        -- The log is loaded once it has reported after login: from now on an
        -- empty read is a real empty log, and mutes may be pruned.
        logReady = true
    end
    if Enabled() then ScheduleRebuild() end
end)
C.RegisterEvents(eventFrame, "PLAYER_LOGIN", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "QUEST_TURNED_IN", "QUEST_WATCH_UPDATE", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
    "PLAYER_ENTERING_WORLD")

ns.quests = {
    OnUnit = OnUnit, OnPlateRemoved = OnPlateRemoved, OnUnitDied = OnUnitDied, Tick = Tick,
    ButtonSpecs = ButtonSpecs, Rebuild = Rebuild, ScheduleRebuild = ScheduleRebuild,
    SetEnabled = SetEnabled, Enabled = Enabled, SetOther = SetOther, PrintState = PrintState,
    SetHunt = SetHunt, HuntEnabled = HuntEnabled,
    SetMute = SetMute, QuestMuteKey = QuestMuteKey, TargetMuteKey = TargetMuteKey,
    ToggleAlert = ToggleAlert, AlertOn = AlertOn,
    -- The last read of the log, for the quest pane (Phase 4). Read only.
    QuestList = function() return questList end,
}

-- Test seam (tests/). Harmless in game.
ns.quests._test = {
    members = members, holders = holders, Associate = Associate, Select = Select,
    NpcIdFromGuid = NpcIdFromGuid, QUEST_MAX = QUEST_MAX, NEAR_IN = NEAR_IN, NEAR_OUT = NEAR_OUT, HUNT = HUNT,
    initialized = function() return loggedIn and logReady end,
    nameRows = function() return nameRows end,
    lastShown = function() return lastShown end,
    alerts = alerts,
}
