# Stakeout

**Stakeout** is a lightweight World of Warcraft: Forever addon that watches for the NPCs you choose.
When one appears, it tells you and gives you a button that targets it in one click.

It's useful for rare hunting, patrol watching, event NPCs, or any time you want to react fast when a
specific NPC shows up. The target button was inspired by RestedXP's targeting system.

> **Forever only.** Stakeout 2.0 targets WoW: Forever (1.60.1). TBC Classic Anniversary players can use
> Stakeout 1.0.2, which stays available on CurseForge.

## Features

- Watch a list of NPCs by exact name
- Detects them on **nameplates**, as your **target**, or under your **mouse**
- A small frame with one button per NPC found: **left-click** targets it, **right-click** targets and raid-marks it
- Chat message, taskbar flash and sound alert (17 sounds, plus 7 more with DBM-Core)
- Raises your nameplate range so plates reach further (Forever's default is 45 yards)
- Two NPCs with the same name keep their button until both are dead
- Movable, lockable, scalable frame

## The Forever beta and your settings

The Forever beta client currently **doesn't load addon settings back** after you log out. It's a Blizzard bug
that affects every addon. Your watch list and options start empty each session. Stakeout tells you at
login while this is happening.

**The easy way:** type `/stakeout macro on`, or tick *Keep the list in a character macro* in the config.
Stakeout then keeps your watch list in a character macro called **Stakeout List** (plus *Stakeout List 2*
and *3* for long lists), updates it whenever the list changes, and reads your list back from it at every
login, with nothing to click. It uses one character macro slot, or up to three for a long list
(roughly 30-40 names of typical length fit; Stakeout tells you if some don't). `/stakeout macro off` deletes them. Stakeout only touches a macro with that name if it wrote it, so one of yours is safe.

**By hand**, if you'd rather not use a macro slot:

1. **Before you log out**, while your list is still there, open the config (`/stakeout`) and click
   **Export**, or type `/stakeout export`. Export copies the list you have now; it can't bring back a
   list that is already gone.
2. Each line in the box is a complete `/stakeout add ...` command that fits in one macro. Put each line in
   its own macro, or keep the lines in a text file.
3. After logging in, click the macro(s), or paste the lines into chat. Your whole list is back.

## Usage

```text
/stakeout                        Open the config panel (also /stake)
/stakeout add <Name>             Add an NPC
/stakeout add <Name>; <Name>     Add several at once
/stakeout remove <Name>          Remove an NPC
/stakeout list                   List the watch list in chat
/stakeout export                 Copy the list as /stakeout add lines
/stakeout macro on / off         Keep the list in a character macro (restored at login)
/stakeout clear                  Remove every NPC
/stakeout reset                  Clear current detections and rescan
```

NPC names must match exactly, spaces included (`/stakeout add Captain Flat Tusk`).

## Configuration

- **Detection:** raise the nameplate range.
- **Alerts:** taskbar flash, sound on/off, and which sound (it previews when you pick it).
- **Raid marking:** turn the right-click mark on or off, and pick the marker. Right-clicking again clears the mark.
- **Target frame:** lock the position (Alt+drag still moves it), the button icon, and the scale.

## What changed from the TBC version

Blizzard's Forever client doesn't allow some of what Stakeout did on TBC:

- **No proximity scanning.** The targeting trick that sensed NPCs outside nameplate range fires for every
  name on Forever, so it can't detect anything. Nameplates, target and mouseover do the detecting now.
- **Marks come from your click.** Addons can't place raid marks by themselves any more, so right-click
  a button to mark.
- **The combat log is closed to addons.** Deaths are tracked another way, with the same result for you.

## Notes

- Stakeout never moves, shows or hides its frame during combat. Changes wait for the fight to end.
- It's designed for your own list, not a built-in rare database.
