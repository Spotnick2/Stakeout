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

_Pending the in-game session._

### 1. TargetUnit proximity trick
### 2. Forbidden-action popup
### 3. NPC name / GUID secrecy
### 4. Deaths: UNIT_DIED and the combat log
### 5. Secure macro button and combat drag
### 6. Templates
### 7. nameplateMaxDistance
### 8. Sounds
### 9. Raid marker
### 10. Macro persistence
### 11. SavedVariables sentinel
