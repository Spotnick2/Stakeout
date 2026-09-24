# Forever probe: what Stakeout depends on

Measured behaviour on the live client, for the port (#4) and the macro fallback (#5). Addon-agnostic
findings also go into `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`.

Build under test: **1.60.1.69977**. On any other build (`GetBuildInfo()`), regenerate the API dump and
re-measure before trusting anything here.

**Settled; the probe addon has been removed (#2 closed).** It lives on in git history. To re-measure on a new
build, restore it and copy it into the AddOns folder by hand (`deploy.ps1` no longer deploys it):

```powershell
git checkout 462e6c5 -- Tools/StakeoutProbe
Copy-Item -Recurse Tools\StakeoutProbe "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\"
```

Disable Stakeout while probing: the probe's `TargetUnit` and `SetRaidTarget` trials raise forbidden-action
errors of their own.

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
