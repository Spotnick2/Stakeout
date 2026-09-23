# Stakeout tests

Unit tests that run under **Lua 5.1** (the interpreter WoW uses) with no game client. Plain scripts, no
dependencies.

```powershell
pwsh tests/run.ps1                                              # luac -p, then every tests/test_*.lua
& 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_manifest.lua   # one file, from the repo root
```

Use the Lua **5.1** interpreter, not a newer Lua that may be first on `PATH`.

- `harness.lua`: `H.check`, `H.eq`, `H.done`, plus TOC readers.
- `test_manifest.lua`: `Stakeout.toc` and `.pkgmeta`. Neither is Lua, and nothing else can see a mistake in them.
- A new test is `tests/test_<area>.lua`; `run.ps1` and CI pick it up automatically.

The port (#4) adds `wow_stubs.lua`: a Forever API stub with **strict globals**, so reading any global it doesn't
define is an error. The stub is the list of APIs verified present on this client, so it must model the
client's absences too. Never add a global to it because a test failed. Confirm it in the API dump (and,
for behaviour, `docs/FOREVER-PROBE.md`) first.

Mutation-test your claims: break the behaviour on purpose and check the suite goes red.
