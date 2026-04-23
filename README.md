# Stakeout

**Stakeout** is a lightweight World of Warcraft Classic addon that watches for NPCs you choose and helps you react quickly when they appear.

It can detect tracked NPCs through nearby nameplates, mouseover, and a proximity-based targeting check, then surface them in a clickable target frame so you can target them instantly.

## Features

- Track a custom list of NPCs by exact name
- Detect NPCs through:
  - nameplates
  - mouseover
  - proximity polling
- Show a clickable target frame for detected NPCs
- Auto-mark detected NPCs with a raid marker
- Optional taskbar flash on detection
- Optional sound alert on detection
- Configurable target frame scale
- Lockable / movable target frame
- Optional max nameplate distance support
- Per-character saved settings

## How it works

Stakeout keeps a watch list of NPC names that you define.

When one of those NPCs is detected, the addon can:

- announce it in chat
- flash the client icon
- play a sound
- add a raid marker
- show a clickable button that targets the NPC by exact name

This makes it useful for rare hunting, patrol watching, event NPCs, or any situation where you want fast reaction to a specific NPC appearing nearby.

## Installation

1. Download or package the addon.
2. Extract the folder so it sits here:

```text
World of Warcraft\_classic_era_\Interface\AddOns\Stakeout
```

3. Make sure the folder contains:
   - `Stakeout.toc`
   - `Stakeout.lua`

4. Launch the game and enable **Stakeout** from the AddOns list.

## Usage

### Open the config

Use:

```text
/stakeout
```

or

```text
/stake
```

This opens the configuration panel.

### Add NPCs to track

You can add NPCs from the config window, or by slash command:

```text
/stakeout add NPC Name
```

Example:

```text
/stakeout add Doomwalker
```

NPC names must match exactly.

### Remove NPCs

```text
/stakeout remove NPC Name
```

### List tracked NPCs

```text
/stakeout list
```

### Clear the watch list

```text
/stakeout clear
```

### Reset current detections and rescan

```text
/stakeout reset
```

## Commands

```text
/stakeout                Open config panel
/stake                   Alias for /stakeout
/stakeout add <NPC Name> Add an NPC to the watch list
/stakeout remove <NPC Name> Remove an NPC from the watch list
/stakeout list           List tracked NPCs in chat
/stakeout clear          Remove all tracked NPCs
/stakeout reset          Clear detections and rescan
```

## Configuration options

Stakeout includes options for:

### Detection

- Enable or disable proximity scanning
- Increase nameplate distance to maximum supported range

### Alerts

- Flash taskbar icon on detection
- Play sound on detection
- Choose alert sound from 30+ options (UI sounds, bells, horns, PvP, atmospheric, and DBM-Core sounds if installed)

### Raid marking

- Enable automatic raid marking
- Choose which raid marker to apply

### Target frame

- Lock or unlock frame position
- Change the button icon style
- Adjust frame scale

### Watch list management

- Add NPCs
- Remove NPCs
- Clear all tracked NPCs
- Reset current detections

## Target frame

When a tracked NPC is detected, Stakeout can show a small clickable frame with one button per detected NPC.

Clicking a button targets that NPC by exact name.

If the addon has a live unit reference available, it will try to show that NPC’s portrait on the button. Otherwise it falls back to the configured icon.

## Notes

- NPC names must be entered exactly.
- This addon is designed for user-defined NPC tracking, not a preloaded rare database.
- Proximity detection is a fallback and may behave differently depending on game restrictions and client behavior.
- Detection handling is conservative in combat when secure UI restrictions apply.
- Saved settings are stored per character.

## Compatibility

Designed for WoW Classic-era clients using the addon interface version in the TOC.

## Credits

Stakeout is a standalone NPC detection addon built around a configurable watch list and a fast clickable targeting workflow. It was inspired by the target system of Rested XP.
