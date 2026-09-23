# Forever probe: what Stakeout depends on

Measured behaviour on the live client, for the port (#4) and the macro fallback (#5). Addon-agnostic
findings also go into `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`.

Build under test: **1.60.1.69977** (check `/soprobe client` → `GetBuildInfo` first; if it differs,
regenerate the API dump before trusting anything here).

## Runbook

Deploy only the probe. The unported TBC addon would get in the way, so the script refuses to deploy it,
and if a copy is already installed, disable it in the AddOn list:

```powershell
pwsh Tools\deploy.ps1 -ProbeOnly
```

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

Session 1: 2026-09-23, build 1.60.1.69977, with !BugGrabber and DBM-Core loaded. Sections still marked _pending_ need more runs.

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
  'UNKNOWN()'"). A 0.25 s poll across a watch list would flood it. **This needs a decision in #4.**
- _Pending:_ trials after `/cleartarget` with a distant NPC, a dead one and a made-up name. The made-up name is the
  control: if the event fires for it too, the trick can't tell presence from absence on this client.

### 2. Forbidden-action popup
No popup 0.5 s later, but this is **confounded**: !BugGrabber takes over `ADDON_ACTION_FORBIDDEN` itself. _Pending:_
the `client` → `popups` lines, and a rerun with !BugGrabber disabled.

### 3. NPC name / GUID secrecy
Out of combat, the target's name and GUID read in the clear (`"Cursed Darkhound"`,
`Creature-0-4615-0-72272-1548-00003425F6`). _Pending:_ `/soprobe unit` in combat.

### 4. Deaths: UNIT_DIED and the combat log
```
CombatLogGetCurrentEventInfo                nil
C_CombatLog.IsCombatLogRestricted           true
C_CombatLogInternal.GetCurrentEventInfo     API MISSING
C_CombatLogSecure.GetCurrentEventInfo       API MISSING
```
Both namespaced readers are **declared in the dump but absent at runtime** for an addon, and the combat log reports
itself restricted. The `UNIT_DIED` event is the only death signal. _Pending:_ `/soprobe watch` to confirm it fires with a GUID matching the plate.

### 5. Secure macro button and combat drag
_Pending._

### 6. Templates
_Pending_ (the `client` output above `combatlog` was not captured).

### 7. nameplateMaxDistance
_Pending_ (same).

### 8. Sounds
Every **numeric** entry plays: some as SoundKit IDs, while Horn of Cenarius, Horn: Dwarf, Foghorn and Boat Warning play only through the
`PlaySoundFile` FileDataID fallback. All 7 DBM-Core sounds play.

**All 9 game-file path strings are refused** (Bell: Alliance/Horde/Night Elf/Karazhan, Ogre War Drums, Troll Drums,
Fireworks, Goblin Spring, Gnome Yell). The Retail client plays built-in game sounds by FileDataID, not by path. Addon-shipped paths (DBM) still work.
→ #4 drops those entries, or replaces them with FileDataIDs that have been verified.

### 9. Raid marker
_Pending._

### 10. Macro persistence
`GetNumMacros()` → `0, 0` on this character. `MAX_ACCOUNT_MACROS` and `MAX_CHARACTER_MACROS` are **nil** on this client, so the
slot limit has to come from the create result, not a constant. _Pending:_ create/edit/big and the two full exits.

### 11. SavedVariables sentinel
_Pending._
