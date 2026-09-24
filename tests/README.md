# Stakeout tests

Unit tests that run under **Lua 5.1** (the interpreter WoW uses) with no game client. Plain scripts, no
dependencies.

```powershell
pwsh tests/run.ps1                                              # luac -p, then every tests/test_*.lua
& 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_manifest.lua   # one file, from the repo root
```

Use the Lua **5.1** interpreter, not a newer Lua that may be first on `PATH`.

- `harness.lua`: `H.check`, `H.eq`, `H.done`, plus TOC readers.
- `wow_stubs.lua`: the Forever API surface Stakeout uses, driven through `WoW` (`WoW.SetUnit`, `WoW.fire`,
  `WoW.inCombat`, `WoW.loadAddon`). It is strict in two ways:
  - **Globals:** reading one the stub doesn't define is an error. The stub is the list of APIs verified present
    on this client, and `KNOWN_ABSENT` models the absences.
  - **Widget methods:** there is no catch-all, so calling a method the stub lacks errors instead of silently passing.
    Protected frames (those parenting secure buttons) raise if moved, shown or hidden in combat.

  Never add either kind because a test failed. Confirm it in the API dump (and, for behaviour,
  `docs/FOREVER-PROBE.md`) first.
- `test_detection.lua`: sightings, secret reads, `UNIT_DIED` with same-name NPCs, expiry, combat, marking.
- `test_slash.lua`: bulk add, export lines (≤255 chars, round-trip), the commands.
- `test_settings.lua`: the one write path (a source scan), the sentinel, the nameplate range, event reporting,
  and that the forbidden APIs are never called.
- `test_login.lua`: a session where settings *did* load, on another build.
- `test_macros.lua`: the watch list in character macros: on/off, following every change, spilling into
  more macros, combat deferral, a player's own same-named macro, full slots.
- `test_macros_login.lua`: restoring from the macros at login and at the first `UPDATE_MACROS`, without duplicates,
  and without bringing back a name removed in combat.
- `test_frames.lua`: executes every script handler, in and out of combat.
- `test_manifest.lua`: `Stakeout.toc` and `.pkgmeta`.
- A new test is `tests/test_<area>.lua`; `run.ps1` and CI pick it up automatically.

Mutation-test your claims: break the behaviour on purpose and check the suite goes red.
