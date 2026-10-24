# Claude Instructions

Read [AGENTS.md](AGENTS.md) for project-specific agent instructions.

## Consulting Codex

The shared `codex-consult` skill (user level) has the invocation and the gotchas. For this repo:

For Stakeout specifically, good things to hand Codex: anything touching the secure target buttons
(`macrotext` / `macrotext2`, `RegisterForClicks`, what combat lockdown defers), how a unit's name
and GUID are read and compared (secret values), the `UNIT_DIED` / detection bookkeeping, the
settings write path, or a change to the `StakeoutDB` shape.

**Always hand it `docs/FOREVER-PROBE.md` and `AGENTS.md` alongside the diff.** Those findings are
measured on the live client, and a cold reviewer will otherwise argue from Classic-era or Retail
behaviour that doesn't hold here: that the `TargetUnit` proximity trick fires for every name, that
`SetRaidTarget` and registering the combat log are forbidden, that SavedVariables never load back.
`C:/Projects/WoW/References/Forever/api/forever-api-<version>.<build>.md` (take the highest build) is the full API surface if a question turns
on whether something exists.
