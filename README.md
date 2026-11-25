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
- A small frame with one button per NPC found: **left-click** targets it and puts your raid marker on it,
  **right-click** only targets it
- Two layouts for that frame: **icons**, or a **list** of rows with each NPC's portrait, its whole name and its
  quest progress ("3/10", "turn in"), in one or two columns (a very long name ends in "...", its tooltip has it
  all). Your current target's button has a gold outline
- A button keeps its NPC's portrait once you've seen it, even out of sight (Stakeout keeps up to 30 portraits)
- Chat message, taskbar flash and sound alert (26 sounds, plus 7 more with DBM-Core)
- Experimental quest buttons (a checkbox in the config, or `/stakeout quests on`): mobs named in unfinished kill
  objectives, and with Questie installed, the mobs that drop quest items and the NPC to turn a finished quest in to
- An optional hunt mode for quest mobs (with Questie): a button before you see them, to click until one is in reach
- An approximate distance in a button's tooltip while its NPC is visible
- Two NPCs with the same name keep their button until both are dead
- Movable, lockable, scalable frame, shrunk to fit the screen when your scale would make it too big

## Your settings

Stakeout keeps your watch list and options between sessions. If the client ever fails to load them back,
Stakeout tells you at login, and the backups below keep your list.

**A macro backup:** type `/stakeout macro on`, or tick *Save list in a character macro* in the config.
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
/stakeout layout icons / list / list2   The target frame: icons, or rows with whole names (list2: two columns)
/stakeout quests on / off        Show experimental quest target buttons
/stakeout quests hunt on / off   Show quest mobs before you see them (with Questie)
/stakeout clear                  Remove every NPC
/stakeout reset                  Clear current detections and rescan
```

NPC names must match exactly, spaces included (`/stakeout add Captain Flat Tusk`).

## Configuration

- **Alerts:** taskbar flash, sound on/off, and which sound (it previews when you pick it).
- **Raid marking:** left-click a button to target the NPC and put your marker on it (clicking again keeps the
  mark); right-click only targets. Turn the mark off, or pick the marker.
- **Target frame:** lock the position (Alt+drag still moves it), the layout, the button icon, and the scale.
  The layout is *Icons* (the default), *List* (a row per NPC: portrait, whole name, quest progress) or *List,
  two columns*. Your current target's button has a gold outline.
- **Look:** WoW Forever (the default) or Glass, a smoked glass look shared with other glass addons. It
  applies to every Stakeout window after a `/reload`.
- **Quest targets:** tick *Show buttons for quest mobs* for the experimental quest buttons (the same switch as
  `/stakeout quests on`), and *Show quest mobs before they're seen* for hunt mode (`/stakeout quests hunt on`).
- **Glass UI:** with Glass UI loaded, Stakeout wears its look (its glass,
  tint and accent) by default. Untick *Use Glass UI appearance* to use your own look instead (after a `/reload`).

## What changed from the TBC version

Blizzard's Forever client doesn't allow some of what Stakeout did on TBC:

- **No proximity scanning.** The targeting trick that sensed NPCs outside nameplate range fires for every
  name on Forever, so it can't detect anything. Nameplates, target and mouseover do the detecting now.
- **Marks come from your click.** Addons can't place raid marks by themselves any more, so the mark goes on
  when you left-click a button.
- **The combat log is closed to addons.** Deaths are tracked another way, with the same result for you.

## Notes

- Stakeout never moves, shows or hides its frame or its buttons during combat: those changes wait for the fight
  to end. Only your target's outline and a newly seen NPC's portrait update mid-fight.
- It's designed for your own list, not a built-in rare database.
- Quest targets are off by default and don't alert on their own. Without Questie, they cover only mobs named in
  unfinished kill objectives. With Questie, a mob that drops a quest item gets a button once you see it, and the
  NPC to turn a finished quest in to gets one while you're within about 80 yards of where Questie says they stand.
  Questie has no droppers for many of Forever's own quest items; those get no button.
- Hunt mode (off by default, needs Questie) gives the mobs your unfinished quests want a button as soon as Questie
  knows they spawn within about 80 yards of you, nearest first, in the slots mobs you can see leave free. Its tooltip says "Not seen
  yet". Clicking it looks for one by name: if one is in reach it becomes your target. It's your click, not
  detection, so nothing alerts until you find one.
- **Shift+right-click a quest button** to be told when one of its mobs appears: the same chat line, flash and
  sound as the watch list, when one gets a nameplate (about 40 yards). A small mark shows on the button while
  it's on. One that leaves and comes back within a minute doesn't alert twice; when the one you saw last dies,
  its respawn alerts at once. For a respawn you're waiting for, hunt mode keeps its button there to click.
- Hover a button to see roughly how far its NPC is (e.g. "25-30 yd"), while a nameplate, your target or your
  mouse shows it. Addons can't read other units' positions, so it's bracketed with range checks, as
  NameplateDistance by Nedyar does (MIT; its notice is
  in `Range.lua`).

## Sounds

Six of the alert sounds (`Media/*.ogg`, from NodeRadar) are royalty-free sound effects from
[Pixabay](https://pixabay.com), under the [Pixabay Content License](https://pixabay.com/service/terms/), not MIT.
They ship inside Stakeout only.

| File | Pixabay | By |
|---|---|---|
| `Sonar.ogg` | "sonar ping", #95840 | freesound_community |
| `RadarBlip.ogg` | "radar ping", #306440 | user 49053354 |
| `DeepSea.ogg` | "deepsea sonar", #386156 | Dragon Studio |
| `BellChime.ogg` | "clear bell chime", #487898 | Universfield |
| `Notification.ogg` | "new notification 016", #350210 | Universfield |
| `HudPing.ogg` | "sci-fi HUD notification ping", #547867 | vadim_makes_sound |

## License

Stakeout is licensed under the MIT License. See the
[license and third-party notices](https://github.com/Spotnick2/Stakeout/blob/main/LICENSE).
