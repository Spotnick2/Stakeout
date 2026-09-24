# Changelog

## 2.0.0 - 2026-09-24

**Stakeout now runs on World of Warcraft: Forever.** This version is for Forever only. TBC Classic Anniversary
players can keep using 1.0.2, which stays available on CurseForge. There will be no further TBC updates.

Forever is still in beta, and Blizzard has changed what addons are allowed to do there. Some of what
Stakeout did on TBC is no longer possible, so please read what changed below.

### Your watch list resets every session (a Blizzard beta bug)

The Forever beta client saves addon settings but never loads them back, for any addon. Every
login starts with an empty watch list and default options. Until Blizzard fixes it:

- Add several NPCs at once: `/stakeout add Mother Fang; Gruff Swiftbite; Fedfennel`
- **Before you log out**, while your list is still there, open **Export** in the config (or type
  `/stakeout export`). It gives your list as ready-made `/stakeout add ...` lines. Put each line in its
  own macro, or keep them in a text file, and use them after you log in. Export can only copy the
  list you have now, so it can't recover a list that is already gone.

Stakeout tells you at login while the bug is present, and stops saying so once your settings come back.

### Removed: proximity scanning

On Forever, the targeting trick Stakeout used to sense NPCs outside nameplate range fires for every name,
whether the NPC is there or not, so it can't detect anything. It's gone, and so is its option. Detection now uses
**nameplates, your target and your mouseover**. Stakeout raises your nameplate range (the Forever default
is 45 yards) so plates reach further.

### Changed: raid marks are now a right-click

Addons can no longer place raid marks on their own. **Right-click** a Stakeout button to target the NPC
and mark it in one click. Right-click again to clear the mark. Pick the marker in the config; turn the
right-click mark off there if you don't want it.

### Also new

- Two NPCs with the same name keep their button until **both** are dead.
- Once Stakeout stops showing an NPC, it stays quiet for 60 seconds before it can alert again, so walking
  in and out of range doesn't spam alerts. If you saw it die, it alerts again straight away when it respawns.
- An NPC whose name loads a moment late is still caught.
- A player's pet that happens to be named like a rare is ignored.
- The Stakeout frame never moves or changes during combat; changes wait for the fight to end.

### Sounds

Nine sounds that Forever refuses to play were removed (the four bells other than Dwarf/Gnome, Ogre War Drums, Troll Drums,
Fireworks, Goblin Spring, Gnome Yell). If you had one selected, Stakeout uses Raid Warning. The DBM-Core
sounds still work when DBM is installed.

## 1.0.2 - 2026-04-23

### Added
- Alert sound selection: choose from 30 sounds in the Alerts config section. Includes UI alerts (Raid Warning, Ready Check, Whisper, Alarm Clock), creature sounds (Murloc Aggro, Loatheb), bells (Alliance, Horde, Night Elf, Karazhan, Dwarf/Gnome), horns (Horn of Awakening, Horn of Cenarius, Dwarf), nautical (Foghorn, Boat Warning), PvP sounds, atmospheric sounds (Ogre War Drums, Troll Drums, Fireworks, Goblin Spring, Gnome Yell), and 7 additional sounds if DBM-Core is installed (Algalon, Illidan, Kil'Jaeden, Air Horn, etc.). The selection previews immediately on click and is saved per character.

## 1.0.0 - 2026-04-08

Initial release
