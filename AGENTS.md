# Stakeout Agent Instructions

Trust these instructions. Search the codebase only when information here is incomplete, stale, or
appears incorrect.

## Review policy

Use `$wow-addon-review` as the shared source of truth for review routing, committed-diff scope,
client/API evidence handling, validation, finding format, and merge-readiness verdicts.

Repository-specific additions:

- Post every pull-request review and follow-up review on the PR, then link the posted review in the
  final response.
- Match `MEASURED_ON_BUILD` in `Stakeout.lua` to
  `C:/Projects/References/forever-api-<version>.<build>.md`. Runtime measurements live in
  `docs/FOREVER-PROBE.md`; addon-agnostic Forever findings live in
  `C:/Projects/References/PORTING-TBC-TO-FOREVER.md`.
- For an adversarial second opinion on a plan or a risky diff, use `/codex-consult`
  (`.claude/skills/codex-consult`).

## What This Repository Is

Stakeout is a World of Warcraft addon for **WoW: Forever 1.60.1** (Interface `16001`). The player
keeps a watch list of NPC names. When one shows up on a nameplate, as the target or under the mouse,
Stakeout alerts (sound, taskbar flash, chat) and shows a clickable button that targets it by exact name.

**TBC Classic Anniversary is no longer supported.** v1.0.2 was the final TBC release. It stays
downloadable on CurseForge, and the code is archived on the `tbc-anniversary` branch / `v1.0.2` tag.
Don't add flavor branching for it.

Forever is *Vanilla content running on Blizzard's Retail (Mainline) codebase*: content assumptions
are Vanilla, API assumptions are Retail. Read `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`
before touching an unfamiliar API.

Port status: the port itself is issue #4. Until it merges, `Stakeout.lua` is still the TBC code and
`Stakeout.toc` still says `20505`. `Tools/deploy.ps1` refuses to deploy it to Forever.

## Repository Layout

- `Stakeout.toc`: manifest (interface, SavedVariables, load order).
- `Stakeout.lua`: the whole addon, in labelled sections (defaults and settings, target frame,
  detection, config GUI, events, slash commands). It stays a single file.
- `tests/`: Lua 5.1 unit tests, no game client. `pwsh tests/run.ps1`.
- `Tools/deploy.ps1`: deploys to the local Forever AddOns folder. `Tools/StakeoutProbe/` is the
  throwaway in-game probe (`/soprobe`); keep it until `docs/FOREVER-PROBE.md` is settled.
- `docs/FOREVER-PROBE.md`: what was measured on the live client, and how.
- `.github/workflows/package-check.yml`: syntax check, tests, and a dry-run package on every PR.
- `.pkgmeta`, `README.md`, `CHANGELOG.md`: packaging and user-facing material.

No dependencies, no libraries, no build step.

## What the Client Allows (measured, build 1.60.1.69977)

Details and raw captures are in `docs/FOREVER-PROBE.md`. Don't re-derive these; re-measure with the probe
if the build changes.

- **No proximity scanning.** `TargetUnit(name, true)` raises `ADDON_ACTION_FORBIDDEN` (`"UNKNOWN()"`) on
  *every* call, for names that don't exist too, so it can't detect anything. RXPGuides disables it on Forever
  for the same reason. Don't bring it back.
- **No addon-placed raid marks.** `SetRaidTarget` from addon code is forbidden. Marking happens through the
  player's click on a secure button (`type2="macro"`, `macrotext2="/tm <index>"`).
- **No combat log.** Registering `COMBAT_LOG_EVENT_UNFILTERED` is forbidden (returns `false` and raises a
  forbidden action), and there is no reader. Deaths come from the **`UNIT_DIED`** event (payload: GUID).
- **SavedVariables are written but never read back**, per-character included. Every session starts from
  defaults, the watch list too. Test persistence only with a **full client exit**, never `/reload`, and never by reading the SV file.
- **`PlaySoundFile` refuses built-in game-file paths.** Use SoundKit IDs or FileDataIDs; paths into other
  addons' folders (DBM-Core) still work.
- **`nameplateMaxDistance` defaults to 45.** Never lower it.
- All the UI templates the config uses exist (`UIDropDownMenuTemplate`, `OptionsSliderTemplate`, …).

## WoW API And Lua Rules

- Target the **Retail/Mainline** API. Keep `## Interface: 16001`. The format is `%d%02d%02d`;
  `11601` is a transposed-digit bug you'll see in the wild.
- Evidence for what exists is the build-matched `C:/Projects/References/forever-api-<version>.<build>.md`, or `/api search <name>` in game.
  Evidence for how something *behaves* is `docs/FOREVER-PROBE.md`. The dump lists things that are nil at runtime
  (`C_CombatLogInternal.GetCurrentEventInfo`).
- **Unit names and GUIDs may be secret values.** A secret throws when it's compared or truth-tested, not only
  when it's read. Read *and* compare inside one `pcall`, and treat a secret as "no name", never as "not on the list".
- `RegisterEvent` throws on an unknown event, and a `false` return is also a refusal. Register through the
  addon's reporting wrapper, never bare.
- Don't write version ladders (`select(4, GetBuildInfo()) > 40000 and …`). 16001 lands in the "Classic" bucket by
  accident. Write the Forever value explicitly.
- `ReloadUI()` is protected; use the `/reload` slash command. Errors are off by default
  (`/console scriptErrors 1`) and stop being delivered after 100 in a session.
- Lua 5.1. `0` is truthy, so `x or default` doesn't guard a numeric that can be 0.

## Secure UI Rules

- The target frame parents `SecureActionButtonTemplate` buttons, which makes it **protected**. In combat,
  don't show, hide, move, resize or re-anchor it, don't start a drag on it, and don't `SetAttribute` its buttons. Defer to
  `PLAYER_REGEN_ENABLED`.
- Buttons register **both** mouse edges (`RegisterForClicks("AnyUp", "AnyDown")`). The client's secure
  handler acts on exactly one of them (`ActionButtonUseKeyDown`). Never set `typerelease`, because that double-fires.
- No `SecureHandler*`, `_onstate-*` or state drivers: secure snippets are broken on this client.

## Settings

Every write to `StakeoutDB` goes through the settings write path in `Stakeout.lua` (one function,
so Blizzard's SavedVariables fix or a migration lands in one place). `svLoadCheck` is written every
session and never defaulted; it is how the addon notices the client started loading settings again.
Don't add it to the defaults.

## Workflow

Work is tracked on GitHub (`Spotnick2/Stakeout`) and lands through pull requests.

1. **Open an issue first**, with enough context to review against.
2. **Branch** off `main`. Never commit to `main` directly.
3. **Open a PR** referencing the issue (`Closes #N`). `package-check` runs on every PR.
4. **Review before merge** with `$wow-addon-review`, posted on the PR. Fix, then post a follow-up.
5. Squash-merge, then delete the branch.

Commit messages: a short imperative subject; a body only if it adds something; end with the model's
`Co-Authored-By:` trailer.

## Releasing

CurseForge (project `1508654`) builds from the repository **webhook** when it sees a tag, and publishes
`CHANGELOG.md` as the release notes.

1. Add a `## <version> - <date>` section at the top of `CHANGELOG.md`, written for players, not from the diff.
   Anything that resets or behaves differently after updating gets its own heading.
2. Commit the changelog, **then** tag: `git tag v2.0.0 && git push --tags`. A tag without a changelog entry
   publishes the previous release's notes against the new build.
3. The tag name picks the channel: `alpha` → Alpha, `beta` → Beta, anything else → Release. Almost nobody opts into
   Alpha or Beta, so ship a Release unless the build should be held back. The *game* being in beta is not a reason; say that in the notes.
4. Download the published file and check it contains only `Stakeout/Stakeout.toc` and `Stakeout/Stakeout.lua`, flagged Forever.

**Do not add a release workflow.** Running `BigWigsMods/packager` on a tag would publish a second time
alongside the webhook. The CI workflow is a dry run (`-d`) and publishes nothing.

## Validation

Offline, on every change:

```powershell
pwsh tests\run.ps1        # luac -p + all unit tests (Lua 5.1)
```

In game:

```powershell
pwsh Tools\deploy.ps1            # the addon (refuses until the TOC says 16001)
pwsh Tools\deploy.ps1 -Probe     # plus the probe
```
```
/console scriptErrors 1
/reload
```

- AddOn list: enabled **and not flagged out of date** (this client doesn't hard-block a wrong interface
  number, so "it loaded" proves nothing).
- Add a nearby NPC → nameplate detection, alert, button. Left-click targets it; right-click marks it. Test in and out of combat.
- Kill it → its button clears. Two NPCs with the same name → the button stays until both are dead.
- Combat: no Lua errors, and the frame isn't touched until combat ends.
