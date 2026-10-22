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
--   * A data provider, ns.questData, when one is set (Phase 3: QuestieDB). It
--     knows each objective's NPCs, the droppers of an item and who ends a
--     quest. Its interface is described below.
-------------------------------------------------------------------------------
local _, ns = ...
local C = ns.core

local fmt              = string.format
local tinsert, tsort   = table.insert, table.sort
local GetTime          = GetTime

local LINGER    = C.LINGER   -- the watch list's: seconds a target stays after it was last seen
local QUEST_MAX = 8          -- quest buttons at most; the watch list's are outside this
local REBUILD_DELAY = 0.2    -- quest events come in bursts (FOREVER-PROBE.md, `events`)

-- The tiers a target can be in. NEAR is the "near its spawn" signal Phase 3
-- adds; nothing sets it yet, but the selection already ranks it.
local VISIBLE, LINGERING, NEAR, NONE = 3, 2, 1, 0

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
-- lastSeen, near, nearSince, dist }. tokens are the unit tokens showing it now
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

-- Experimental, and off until the player turns it on (/stakeout quests on).
local function Enabled()
    return StakeoutDB ~= nil and StakeoutDB.questTargets == true
end

local function OtherEnabled()
    return StakeoutDB ~= nil and StakeoutDB.questOther == true
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
    m.observed = name
    m.unit = token
    m.lastSeen = GetTime()
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
        m.dbName, m.refs = w.dbName, w.refs
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

    -- Units already on screen match the new set now, not at their next event.
    -- The core's watch state is untouched, so a watched unit doesn't alert again.
    C.Rescan()
    dirty = true
    Flush()
end

local function ScheduleRebuild()
    if rebuildPending then return end
    rebuildPending = true
    C_Timer.After(REBUILD_DELAY, Rebuild)
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

local function OnUnit(unit, isPlate, name, guid)
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
    Flush()
end

local function OnPlateRemoved(token)
    if not Enabled() or type(token) ~= "string" or not holders[token] then return end
    for m in pairs(holders[token]) do Release(m, token) end
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
    Flush()
end

-- The 1 s tick: drop tokens that stopped showing a member (a missed plate
-- removal must not keep a button forever), keep the visible ones fresh, and
-- end sightings LINGER seconds after they were last seen.
local function Tick()
    if not Enabled() then return end
    local now = GetTime()
    for _, m in pairs(members) do
        for token in pairs(m.tokens) do
            local name, guid = C.ReadNPC(token)
            if not Shows(m, name, guid) then Release(m, token) end
        end
        ExpireGuids(m, now)
        if next(m.tokens) then
            m.lastSeen = now
        elseif m.lastSeen and now - m.lastSeen > LINGER then
            EndSighting(m)
        end
        if members[m.key] == m then Touch(m) end
    end
    Flush()
end

-------------------------------------------------------------------------------
-- Selection: which targets get one of the QUEST_MAX buttons
--   1. One slot is reserved for a turn-in, only when an eligible one exists:
--      seen before near-only, then the nearest, then by name.
--   2. Tiers: visible > lingering > near. Kill and item rank equally; other
--      quest units come last in each tier.
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

    for tier = VISIBLE, NEAR, -1 do
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
        tooltip[#tooltip + 1] = "Left-click: target"
        if StakeoutDB.enableMarking then
            local marks = Marks(nt.row)
            count[nt.row] = count[nt.row] + 1
            local mark = marks[(count[nt.row] - 1) % #marks + 1]
            if mark then
                -- !N keeps the mark on a second click; /tm N would take it off.
                right = fmt("%s\n/tm !%d", left, mark)
                tooltip[#tooltip + 1] = "Right-click: target and mark"
            end
        end
        specs[#specs + 1] = {
            row = nt.row, name = nt.name, macrotext = left, macrotext2 = right,
            unit = nt.unit, icon = QUEST_ICON, tooltip = tooltip,
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

local function SetMute(key, on)
    if not C.SetQuestMute(key, on) then return false end
    dirty = true
    Flush()
    return true
end

local function PrintState()
    if not Enabled() then
        C.Print("Quest targets (experimental): |cffff6666off|r. |cff00ff00/stakeout quests on|r to try it.")
        return
    end
    C.Print("Quest targets (experimental): |cff00ff00on|r, %d quests read. |cff00ff00/stakeout quests off|r " ..
        "turns them off.", #questList)
    if not HasProvider() then
        C.Print("Without quest data (Questie), only mobs you see whose name is in a kill objective get a button.")
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
    SetMute = SetMute, QuestMuteKey = QuestMuteKey, TargetMuteKey = TargetMuteKey,
    -- The last read of the log, for the quest pane (Phase 4). Read only.
    QuestList = function() return questList end,
}

-- Test seam (tests/). Harmless in game.
ns.quests._test = {
    members = members, holders = holders, Associate = Associate, Select = Select,
    NpcIdFromGuid = NpcIdFromGuid, QUEST_MAX = QUEST_MAX,
    initialized = function() return loggedIn and logReady end,
    nameRows = function() return nameRows end,
    lastShown = function() return lastShown end,
}
