# Forever probe: what Stakeout depends on

Measured behaviour on the live client, for the port (#4) and the macro fallback (#5). Addon-agnostic
findings also go into `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`.

Build under test: **1.60.1.70450** (first measured on 1.60.1.69977, re-tested in game on 70338, and Stakeout's own
buttons re-checked on 70450 by `/fp steps so core`, §12). On any later build (`GetBuildInfo()`), regenerate the API dump and
re-measure before trusting anything here.

**Sections 1-11 are settled.** The session-1 probe that measured them (`/soprobe`) was removed (#2 closed) and lives
on in git history at `462e6c5`. Its folder name is now taken by the ForeverProbe module below, so to re-run those trials,
check it out elsewhere (`git worktree add ..\Stakeout-462e6c5 462e6c5`) and copy that `Tools\StakeoutProbe` by hand.
Disable Stakeout while running it: its `TargetUnit` and `SetRaidTarget` trials raise forbidden-action errors.

**Section 12 is the probe for quest targeting (#24, #25):** `Tools/StakeoutProbe`, a ForeverProbe module
(`..\ForeverProbe\docs\GUIDE.md`). Deploy it with `pwsh Tools\deploy.ps1 -Probe`, `/reload`, then follow its
procedures (`/fp steps so <name>`). Its lines go to the `/fp` console and `StakeoutProbe.lua` in SavedVariables, never to
chat.

## Runbook (as run in session 1)

In game, `/console scriptErrors 1`, then run the steps below. Before **each** `target` trial, `/cleartarget`
(the probe warns if you forget), so a success can't look like "no change".

| # | Where | Command | What to do |
|---|---|---|---|
| 1 | anywhere | `/soprobe client` | nothing else |
| 2 | anywhere | `/soprobe sounds` | listen; ~30 s |
| 3 | near a hostile NPC (plate visible) | `/soprobe target <its name>` | also run it for an NPC **far away** (out of plate range but within ~100 yd), a **dead** one, and a **made-up** name |
| 4 | same | `/soprobe popup`, then `/soprobe target <name>` again | did the "blocked from an action" popup appear before and after? |
| 5 | target the NPC | `/soprobe unit` | repeat **in combat** with it |
| 6 | near NPCs | `/soprobe watch` | pull and kill a couple (same-name pair if possible), then `/soprobe watch` to stop |
| 7 | near the NPC | `/soprobe button <its name>` | left- and right-click the icon out of combat, then in combat; drag the brown box in combat |
| 8 | target a hostile NPC, solo | `/soprobe mark` | |
| 9 | out of combat | `/soprobe macro create`, `macro edit`, `macro big`, then `macro edit` **in combat** | |
| 10 | — | **full client exit**, relaunch | the login lines report the macro body and SV counters. Then `/soprobe macro edit`, and do a **second** full exit and relaunch |
| 11 | anywhere | `/soprobe text` | Ctrl+A, Ctrl+C, and paste the log into the matching section below |

Never use `/reload` for items 10–11. It keeps the client process alive and proves nothing about persistence.

## Results

### What RXPGuides does on Forever (v4.11.9-18, `Interface: …, 16001`)

Stakeout copied its targeting from RXPGuides, and RXP ships a Forever build. Its choices there are strong evidence:

- **Proximity scanning is force-disabled** (`SettingsPanel.lua`, `unitscanEnabled`; `DB/forever/rares.lua`):
  *"As of 1.15.8 TargetUnit now fires ADDON_ACTION_FORBIDDEN at execution, rather than target matches."* So the
  event fires on **every** call, whether the NPC is there or not. The trick can't detect anything on this client.
  RXP's handler still matches `"TargetUnit()"`, which is dead code once the feature is off. Our `"UNKNOWN()"` agrees.
- **Addon code does not auto-mark on Forever** (`Targeting.lua` `UpdateMarker`: `if addon.game == "FOREVER" … return`).
  Instead, a right-click on the target button runs a secure `type2=macro`, `macrotext2="/tm <index>"`, so the player's click places the mark.
- **Secret names are treated as absent** (`libs/compatibility.lua` `addon.GetUnitName`: `issecretvalue(n)` → `nil`).
- **The secure `/cleartarget\n/targetexact <name>` button is unchanged** and ships on Forever.
- It still sets `nameplateMaxDistance` through the same `> 40000` ladder (so `"41"` on Forever). That's unmeasured there too.
- It creates and edits its own macros on Forever (`CreateMacro`/`EditMacro`, cap check `GetNumMacros() < 119`). That shows the calls
  work; it doesn't show they persist.

Session 1: 2026-09-23, build 1.60.1.69977, with !BugGrabber and DBM-Core loaded. The follow-ups that were still open are
settled by the port's in-game validation (#9) and the macro report (#2); see items 4, 5 and 10.

### 1. TargetUnit proximity trick

`/soprobe target Cursed Darkhound` with the NPC nearby (but **already targeted**, so the targeting result is ambiguous):

```
event.ADDON_ACTION_FORBIDDEN   {1="StakeoutProbe", 2="UNKNOWN()"} (during TargetUnit)
forbidden fired DURING the call   true
```

- **The function string is `"UNKNOWN()"`, not `"TargetUnit()"`.** Stakeout's current match
  (`func ~= "TargetUnit()"`) would never succeed on this client, so proximity detection is dead as shipped.
- The first argument is the **addon name** (declared `isTainted`, but it carries the name).
- The event fires **synchronously** inside the `TargetUnit` call. Matching on "our addon name, fired while
  `proxScanData` is set" is therefore enough, and it's more robust than matching a function string that already changed once.
- !BugGrabber captures every forbidden call as an error ("AddOn 'StakeoutProbe' tried to call the protected function
  'UNKNOWN()'"). A 0.25 s poll across a watch list would flood it. (Resolved: proximity mode is removed, see below.)
- **Control, measured:** after `/cleartarget`, `/soprobe target Zzzfake Name` (an NPC that doesn't exist):

  ```
  event.ADDON_ACTION_FORBIDDEN   {1="StakeoutProbe", 2="UNKNOWN()"} (during TargetUnit)
  forbidden fired DURING the call   true
  target before -> after            <none> -> <none>
  ```

  **The event fires for a name that doesn't exist.** It carries no information about whether the NPC is present, so the proximity
  trick is dead on this client. That agrees with RXPGuides' Forever build. The distant and dead trials are moot. **Settled: #4 removes proximity mode.**

### 2. Forbidden-action popup
```
StaticPopup1..4                                exists text=false Text=true
StaticPopupDialogs.ADDON_ACTION_FORBIDDEN      defined
UIParent handles ADDON_ACTION_FORBIDDEN        false
```
The popup's text field is `Text`, not `text`. With !BugGrabber loaded, `UIParent` isn't registered for the event at all, so no popup
appears. **Moot now that proximity mode is gone.** Stakeout no longer touches this event or the popups.

### 3. NPC name / GUID secrecy
```
unit.HasSecretRestrictions  true
unit.target      name="Greater Duskbat" guid="Creature-0-4615-0-72272-1553-0000B4265F" secretIdentity=false dead=false compare ok
unit.nameplate1  name="Greater Duskbat" guid="Creature-0-4615-0-72272-1553-0000342808" secretIdentity=false dead=false compare ok
```
The client has secret restrictions, but NPC names and GUIDs on target and nameplate units read and compare in the clear.
_Unconfirmed:_ whether this run was in combat (the chat line doesn't show it; the `/soprobe text` log header does). Either way, #4 keeps
every read inside `pcall` and treats a secret value as "no name" (RXP does the same).

### 4. Deaths: UNIT_DIED and the combat log
```
CombatLogGetCurrentEventInfo                nil
C_CombatLog.IsCombatLogRestricted           true
C_CombatLogInternal.GetCurrentEventInfo     API MISSING
C_CombatLogSecure.GetCurrentEventInfo       API MISSING
```
Both namespaced readers are **declared in the dump but absent at runtime** for an addon, and the combat log reports
itself restricted. The `UNIT_DIED` event is the only death signal.

**Registering `COMBAT_LOG_EVENT_UNFILTERED` is itself a protected action.** `RegisterEvent` returns `false` (no throw) *and* raises
`ADDON_ACTION_FORBIDDEN` (`"UNKNOWN()"`, captured by !BugGrabber). An addon that still registers CLEU on this client gets a
forbidden-action error at every login. `UNIT_DIED` registers fine (`true`).
**Settled by the port's in-game validation (#9, 2026-09-23):** a killed watched NPC's button clears through `UNIT_DIED`
matched on GUID, and a live NPC with the same name keeps its button. The raw `/soprobe watch` kill lines were never captured,
so the relative order of `NAME_PLATE_UNIT_REMOVED` and `UNIT_DIED` on a kill is still unmeasured. The port handles either order
(the GUID→name record outlives the entry).

### 5. Secure macro button and combat drag
Not probed directly. Verified with the port (#9, 2026-09-23): left-click targets, right-click targets and marks (`/tm`), in and
out of combat, on both edges. Dragging the frame in combat gives no Lua or protected-action errors.
`ActionButtonUseKeyDown` is `"1"` on this client, so the down edge acts. Both edges stay registered.

### 6. Templates
All present: `BackdropTemplate`, `UIDropDownMenuTemplate` (+ `UIDropDownMenu_Initialize`), `OptionsSliderTemplate`,
`MinimalSliderWithSteppersTemplate`, `UICheckButtonTemplate`, `UIPanelScrollFrameTemplate`, `UIPanelButtonTemplate`,
`UIPanelCloseButton`, `WowStyle1DropdownTemplate`, `SecureActionButtonTemplate`. `MenuUtil` exists. **The config UI keeps its widgets as they are.**

### 7. nameplateMaxDistance
```
GetCVarInfo  "45.000000", "45.000000", isStoredServerAccount=false, isStoredServerCharacter=true, locked=false, secure=true, readOnly=false
set 41 / 60 / 100  -> each reads back as set
```
**The default is 45**, so the current `version > 40000 and "100" or "41"` ladder (which RXP also ships) *lowers* the range on
Forever. Read-back only proves storage, not the effective plate range the engine applies. #4 sets `"100"` only when it's higher
than the current value, and never lowers it.

### 8. Sounds
Every **numeric** entry plays: some as SoundKit IDs, while Horn of Cenarius, Horn: Dwarf, Foghorn and Boat Warning play only through the
`PlaySoundFile` FileDataID fallback. All 7 DBM-Core sounds play.

**All 9 game-file path strings are refused** (Bell: Alliance/Horde/Night Elf/Karazhan, Ogre War Drums, Troll Drums,
Fireworks, Goblin Spring, Gnome Yell). The Retail client plays built-in game sounds by FileDataID, not by path. Addon-shipped paths (DBM) still work.
→ #4 drops those entries, or replaces them with FileDataIDs that have been verified.

### 9. Raid marker
```
mark.target                 name="Greater Duskbat" ...
event.ADDON_ACTION_FORBIDDEN  {1="StakeoutProbe", 2="UNKNOWN()"}
SetRaidTarget(target, 6)    <no return>
GetRaidTargetIndex          nil
```
**`SetRaidTarget` is protected on Forever.** It raises a forbidden action and places no marker. #4 replaces auto-marking with a right-click
secure `macrotext2="/tm <index>"`, as RXP does.

### 10. Macro persistence
- `MAX_ACCOUNT_MACROS` / `MAX_CHARACTER_MACROS` are **nil**. `CreateMacro(..., true)` returned **121**, so character macros start at
  index 121 (120 account slots before them).
- **Duplicate names are allowed.** A second `CreateMacro` with the same name also succeeded (`GetNumMacros` → `0, 2`).
  `GetMacroIndexByName` returns one of them. #5 must look the macro up before creating it.
- `EditMacro` works out of combat. **A 256-char body was stored as 256**, so there's no 255 cap in memory. Whether the server keeps it is the persistence question.
- **Persistence, reported by the maintainer (#2, 2026-09-24):** macros holding the exported `/stakeout add` lines worked in game,
  restoring the watch list after logging back in. That's the workaround the v2.0.0 notes recommend. The finer points (edits in combat,
  and whether a 256-char body survives the server) weren't measured; `/stakeout export` keeps each line within 255 chars.

### 11. SavedVariables sentinel
Four logins on 2026-09-23 (15:18, 15:28, 15:29, …) all report `launches before 0, 0` for both the account and character tables. **Nothing
loads back**, which agrees with the porting guide. A zero after `/reload` is a valid negative.

### 12. Quest targeting (70450, #25)

What the quest buttons rely on, measured by `/fp so` (`Tools/StakeoutProbe`), Questie 12.1.0 with QuestieDB 1.0.6.

| Procedure | Measures | Where |
|---|---|---|
| `/fp steps so quests` | QuestieDB's contract and area map; the quest log's raw rows, `IsComplete` vs `ReadyForTurnIn` (P1); a kill mob, the same in combat, a dropper, an unrelated NPC, the turn-in NPC: secret or plain, `UnitIsRelatedToActiveQuest`, QuestieDB's name (P2); the turn-in NPC's QuestieDB spawn vs where he stands, map vs world distance (P3); login samples after a `/reload` (P6) | where your quests are, e.g. Durotar |
| `/fp steps so range` | `/tm 8` vs `/tm !8` on a second click; `/targetexact` on the turn-in NPC at 40, 60, 80 and 100 yd (P5) | next to a turn-in NPC |
| `/fp steps so hostile` | `/targetexact` on a quest mob with no nameplate (P5) | near your kill-quest mobs |
| `/fp steps so events` | quest and death events, and when objective rows change, for a kill, a loot, a turn-in and an accept (P6) | while questing |
| `/fp steps so core` | Stakeout's own left-click, right-click mark and `UNIT_DIED` clearing on this build (P8) | anywhere with a mob to kill |
| `/fp steps so corpse` | which unit `/targetexact` picks with a corpse and live mobs of one name around, and whether `/cleartarget [dead]`, a second `/targetexact`, `/target` or a repeat click reaches a live one | by a quest mob you can kill |
| `/fp steps so mulgore` | QuestieDB spawns vs where two NPCs stand, in a zone QuestieDB's Era-to-Forever helper re-projects (P3) | Mulgore |

**Still open:**
- Whether `/targetexact` reaches a live hostile with no nameplate (not needed for v1).
- A turn-in's events (`QUEST_TURNED_IN`) and a kill-credit objective's progress (P6).
- Combat with the quest pane open (P7). That belongs to the pane's own in-game check, since there's no pane yet.

#### `quests` (2026-10-17, 1.60.1.70450, Durotar, level 6, runs #110-111)

**QuestieDB (P4).**
```
LibQuestieDB QuestieDB, readMode baked, contract 4 (min 1); RequireContract(4) true nil
ObjectiveFirst: eventObjectiveFirst=0 itemObjectiveFirst=5 killCreditObjectiveFirst=1 objectObjectiveFirst=0 spellObjectiveFirst=0
area map: 1112 areas in 2.4 ms; 14 -> 1411, 362 -> 1411, 215 -> 1412, 1637 -> 1454
50 reads for the quest log in 0.8 ms
sample ADDON_LOADED: ... 0 quests; LibQuestieDB yes; Questie ready false      (first login)
sample PLAYER_LOGIN: ... 16 quests; LibQuestieDB yes; Questie ready false
sample Questie ready: ... 16 quests; LibQuestieDB yes; Questie ready true     (+5.4 s after ADDON_LOADED; +3.4 s after a /reload)
```
- `LibQuestieDB` is there at our `ADDON_LOADED`, and contract 4 holds. The strict area-map parser reads the shipped strings
  (base plus Override) in 2.4 ms, with the 14→1411 sample. Reads are cheap: 50 in 0.8 ms.
- The quest log is readable at `PLAYER_LOGIN` (16 quests). After a `/reload` it's already readable at `ADDON_LOADED`.
- `Questie.API.isReady` turns true 3-5 s after login. Data reads work before that (step 2 read it fine), so the
  adapter can build at login and rebuild once on ready.

**The quest log (P1).** All 16 quests; a few representative rows:
```
Q 96821 Legging It:        row 1: type monster finished false 0/6 objectiveType 0 text "0/6 Ridgeshade Creeper slain"
Q 818 A Solvent Spirit:    row 1: type item    finished false 1/4 objectiveType 1 text "1/4 Intact Makrura Eye"
                           row 2: type item    finished false 1/8 objectiveType 1 text "1/8 Crawler Mucus"
Q 786 Thwarting Kolkar..:  row 1: type object  finished false 0/1 objectiveType 2 text "0/1 Attack Plan: Valley of Trials destroyed"
Q 823 Report to Orgnil:    IsComplete true  ReadyForTurnIn true, 0 rows
Q 96655 Camping 101: Cooking: IsComplete false, row 1: type object finished false 1/1 objectiveType 14 text "Learn cooking from Cook Torka in Razor Hill"
Q 97905 Camping 101: Herbalism: IsComplete true, row 1: type object finished true 1/1 objectiveType 14 text "Raise your herbalism skill to 20"
Q 97223 Bloodtalon Matriarch: row 1: type item text "0/1 Bloodtalon Matriarch Eggs"; questie item: 277128 Bloodtalon Martriarch Eggs
```
- **`IsComplete` and `ReadyForTurnIn` agreed on all 16 quests** (both true on 823 and 97905, both false elsewhere, never
  nil). The turn-in rule uses `C_QuestLog.IsComplete`; no fallback is needed.
- A delivery quest with nothing to do (823) has **0 rows** and is complete.
- Row text is `"<have>/<need> <name>"`, with `" slain"` / `" destroyed"` after creatures and objects. The QuestieDB names
  appear in it literally, so containment matching works, except where QuestieDB misspells one: item 277128 is
  "Bloodtalon **Martriarch** Eggs". The order fallback (one item entry, one item row) still pairs it correctly.
- **Forever's new objective type 14** ("Learn cooking from…", "Raise your herbalism skill to 20") reports `type "object"`.
  QuestieDB lists the trainer as a *creature* objective there (Cook Torka, Jandi). Type-compatible matching rejects that
  pairing, so the trainer becomes "progress unknown". He must not be labelled a kill target: the model files a creature
  objective with no monster row as a friendly "talk" target. Its row read `finished false 1/1` while the quest wasn't
  complete, so `finished` on type 14 doesn't track the counts.
- **QuestieDB has no droppers for most of Forever's new items** (IDs 247884, 275713-275718, 277135), and none for 4864
  (Minshina's Skull, from an object). Those objectives get no button; the pane lists them as "no known source".
- `ObjectiveFirst` is populated (5 item-first quests, 1 kill-credit-first); none of these 16 were among them.

**Units (P2).**
```
target: name "Makrura Clacker" (str15) guid Creature-0-6782-1-2-3103-C322B76B08 creatureID 3103 related false attackable true reaction 2 dead true
target: name "Pygmy Surf Crawler" (str18) guid Creature-...-3106-9809ECB758 creatureID 3106 related true attackable true reaction 4 dead false combat false
target: name "Pygmy Surf Crawler" (str18) guid Creature-...-3106-9809ECB758 creatureID 3106 related true ... combat true
target: name "Xar'Ti" (str6) guid Creature-...-7953-082DD90EF9 creatureID 7953 related false attackable false reaction 5
target: name "Swift Orange Raptor" (str19) ... creatureID 276801 related false attackable false reaction 5
questie npc <id>: name <same as the client's> (all four)
```
- Names, GUIDs and `UnitCreatureID` are **plain**, for a kill mob and a dropper, **in combat too**. QuestieDB's `Npc.name`
  equals `UnitName` for every NPC read.
- `C_QuestLog.UnitIsRelatedToActiveQuest` is plain: true on a live Crawler, false on a **dead** Makrura and on unrelated NPCs.
- **Not measured:** a turn-in NPC whose quest is complete. Orgnil was out of reach, so Xar'Ti stood in (she ends 97223,
  which wasn't complete): related false.

**Position (P3).**
```
player on map 1411 at 55.21, 75.56 (map 5287 x 3525 yd); nearest spawn 2.8 yd at 55.22, 75.48   (Swift Orange Raptor, standing next to it)
player on map 1411 at 55.21, 75.56; nearest spawn 4.4 yd at 55.28, 75.49                        (Xar'Ti, next to her)
player on map 1411 at 55.34, 80.62; nearest spawn 24.2 yd                                        (a Crawler: mobs wander)
walk: 29.1 yd on the map, 29.1 yd in the world, ratio 0.999
```
- **QuestieDB's stored coordinates match where NPCs stand in Durotar**, within 3-5 yd. Era-converted distances equal the
  stored ones there, as expected (Durotar has the identity transform). Mulgore, which the converter changes, is still open.
- `GetPlayerMapPosition` × `C_Map.GetMapWorldSize` gives the same distance as `UnitPosition` (ratio 0.999), so the yards
  formula is right.
- The `near` list worked: 30 targets, from Sen'jin Village the nearest was a Crawler spawn at 136 yd, and Orgnil was 1153 yd away.

The login samples over six reloads saw at most one nameplate, never with a readable name, so "mobs already visible at login"
is still unmeasured (P6). The rescan after the first rebuild covers it either way.

Screenshot (deleted after reading): Xar'Ti and her raptors, the quest tracker showing *Report to Orgnil* ready.

#### `range` (2026-10-17, 1.60.1.70450, by Xar'Ti, run #111)
```
/tm 8:   click 1 -> mark <secret>;  click 2 -> mark nil
/tm !8:  click 1 -> mark <secret>;  click 2 -> mark <secret>
40 yd:   target Xar'Ti (wanted Xar'Ti) plate false     (37.9 yd at the step, 40.6 at the click)
60 yd:   target Xar'Ti, plate false                    (62.7 yd)
80 yd:   target Xar'Ti, plate false                    (81.3 yd)
100 yd:  target Xar'Ti, plate false                    (99.6 yd)
```
- **`/tm N` toggles; `/tm !N` keeps the mark.** A second `/tm 8` removed the skull (readback `nil`). A second `/tm !8`
  left it (still a secret, which `GetRaidTargetIndex` returns for a marked unit). The owner answered "yes, still there"
  after `/tm 8`, but the readback says otherwise and matches Retail's toggle. Quest buttons use **`/tm !N`**, so clicking
  again to re-target never unmarks.
- **`/cleartarget` + `/targetexact` reached a friendly NPC with no nameplate at 40, 60, 80 and ~100 yd.** The ceiling is
  above 100 yd. The 80 yd friendly radius has room to spare.
- Every click was a right-click (the owner clicked right where the step said left). The right-click macro is
  `/cleartarget`, `/targetexact <name>`, `/tm !8`, so the targeting result is the same; it re-marked each time.
- One click (both edges registered) ran the macro once: the mark didn't toggle twice within a click.
- Distances are from Xar'Ti's QuestieDB spawn, which is 4-5 yd from where she stands.

#### `hostile` (2026-10-17, 1.60.1.70450, Durotar's coast, run #113)
```
target: name "Pygmy Surf Crawler" ... creatureID 3106 related true attackable true reaction 4 dead false plate true
click LeftButton down: target Pygmy Surf Crawler (wanted Pygmy Surf Crawler) plate false mark nil; 67.1 yd from its nearest spawn
Did it target a mob you couldn't see a nameplate for?  NO
note: "as expected it targetted the first dead nearby"
```
- **`/targetexact` took a nearby corpse over a live mob of the same name.** The click "worked" (a Pygmy Surf Crawler was
  targeted, with no plate), but it was a dead one. So this run says nothing about the reach to a live, plateless mob.
- That matters for kill and item buttons: once the player has killed a few, the button may keep landing on corpses.
  How `/targetexact` picks among several matches (nearest? corpses first?), and whether a macro line can skip a corpse,
  is a follow-up probe (see the plan).
- Quest mobs aren't always hostile: this crawler is neutral (reaction 4) and attackable.

#### `corpse` (2026-10-17, 1.60.1.70450, Durotar's coast, run #118)
```
step 1 (read):  Pygmy Surf Crawler dead true unit C6CF6B3C31, 10 yd from its spawn   <- the corpse beside the player
A        /cleartarget | /targetexact X                                  -> live 8B55C76A69
A again  (same)                                                         -> live 8B55C76A69
B        /cleartarget | /targetexact X | /cleartarget [dead]            -> live 539B5CDDB2
C        ... | /cleartarget [dead] | /targetexact X                     -> live 539B5CDDB2
D        /cleartarget | /target X                                       -> live 539B5CDDB2
E        /targetexact X (no clear)                                      -> live 6EC39268FE
E again  (same)                                                         -> live 6EC39268FE
"Did any variant reach a live one while a corpse was closer?"  YES
```
- **With a live one in reach, every variant skipped the corpse at the player's feet** (C6CF6B3C31 was never picked).
  The `hostile` run's corpse was picked when no live one was in reach: the live crawlers had been walked out of
  nameplate range.
- **The pick is deterministic:** the same macro twice gives the same unit, and a repeat click without `/cleartarget` (E)
  doesn't cycle to another one. Which live unit it picks changes as mobs move (A, then B and C, about 12 s apart).
- `/target` (D) picks like `/targetexact` here.
- The `plate` flag at the down edge can read false for a unit that has a plate (E: false on down, true on up), so
  don't trust it in the same frame as the targeting.
- **Decision for mob buttons:** `/cleartarget`, `/targetexact <name>`, `/cleartarget [dead]`. With only corpses in reach,
  the click leaves no target instead of a corpse. With a live one in reach it targets the live one, as A does. The
  right-click adds `/tm !N`, which does nothing without a target. NPC buttons keep A.
- Still open, and not needed for v1: whether a live hostile **without** a nameplate is reachable at all. Mob buttons are
  mostly "seen" buttons anyway.

#### `events` (2026-10-17, 1.60.1.70450, run #114)
```
kill (no quest progress):  UNIT_DIED "Creature-...-3106-..."
loot a quest item:         QUEST_WATCH_UPDATE 818 -> UNIT_QUEST_LOG_CHANGED player (rows already read 2/8) -> QUEST_LOG_UPDATE -> QUEST_LOG_UPDATE (+0.3 s)
abandon:                   UNIT_QUEST_LOG_CHANGED player -> QUEST_REMOVED 97223 false -> QUEST_LOG_UPDATE
accept:                    GOSSIP_SHOW -> QUEST_DETAIL 0 -> UNIT_QUEST_LOG_CHANGED player -> QUEST_ACCEPTED 97223 -> QUEST_LOG_UPDATE -> QUEST_POI_UPDATE
idle:                      QUEST_LOG_UPDATE also fires with nothing changed (3 times in 40 s)
```
- **The objective rows are already updated when `UNIT_QUEST_LOG_CHANGED` fires**, and `QUEST_LOG_UPDATE` follows within
  the same frame. Coalescing those events into one rebuild 0.2 s later is safe.
- `QUEST_REMOVED` carries the quest ID (abandon: second argument `false`). `QUEST_ACCEPTED` carries the quest ID.
- `UNIT_DIED` fires for deaths near the player that they didn't cause (a Makrura died while the owner looted).
- Not measured: a turn-in (skipped, none ready) and a kill that advances a "slain" objective.

#### `core` (2026-10-17, 1.60.1.70450, run #115): Stakeout's own buttons, P8
```
/stakeout add <mob>; left-click: did it target?   YES
right-click: did it mark?                          YES
kill: UNIT_DIED "Creature-...-3125-..." (in combat); did the button go away?  YES
```
**Stakeout 2.1.x works unchanged on 70450**: targeting, marking and `UNIT_DIED` clearing. `MEASURED_ON_BUILD` moves to
70450.

#### `mulgore`, first run (2026-10-17, 1.60.1.70450, another account, run #150): Thunder Bluff, not Mulgore
```
Naal Mistrunner (3027):   area 1638 -> uiMap 1456 (map 1044 x 696 yd); nearest spawn 8.7 yd; as Era-converted 8.7 yd   PASS
Cairne Bloodhoof (3057):  player at 50.95, 51.16; nearest spawn 97.6 yd at 60.3, 51.68                               FAIL
```
- Both NPCs were in **Thunder Bluff** (area 1638 → uiMap 1456), which the Era-to-Forever helper leaves alone (stored =
  converted). Naal's spawn is within 9 yd of where he stands.
- Cairne's FAIL is not a data error: the player had moved about 6 yd since reading Naal, so they targeted Cairne from
  across the bluff. His stored spawn (60.3, 51.7) is on the Elder Rise, where he stands.
#### `mulgore`, second run (2026-10-17, 1.60.1.70450, run #151): Bloodhoof Village
```
Brave Darksky (3220):     area 215 -> uiMap 1412 (map 6154 x 4102 yd); nearest spawn 57.8 yd as stored; as Era-converted 201.2 yd   FAIL
Zarlman Two-Moons (3054): player at 46.91, 61.09; nearest spawn 4.5 yd at 46.88, 61.19 as stored; as Era-converted 137.7 yd       PASS
```
- **QuestieDB's stored coordinates are already in Forever's frame in Mulgore.** Zarlman stands 4.5 yd from his stored
  spawn. Running it through `EraToForever` would put him 138 yd off.
- Brave Darksky is a Bloodhoof guard, 58 yd from his single stored point. Converting makes it 201 yd. Guards patrol, so
  his miss doesn't change the conclusion.
- **Rule confirmed: use QuestieDB's coordinates as stored. Never call `EraToForever` on them.** P3 is closed.
