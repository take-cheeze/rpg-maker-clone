# 26. Testing RPG Maker XP against a released game (Pray for You)

Date: 2026-08-05

## Status

Accepted — the data, script-host and boot checks run green on both the
OpenGame.exe test bed and the packed *Pray for You* release; the wine comparison
stays a manual/dev script, as in ADR 0021 / 0025.

## Context

ADR 0025 set up three runtimes for RPG Maker XP — the native binary, the browser
build and the genuine `RGSS10*.dll` under wine — but pointed all of them at one
project: the `OpenGame.exe` `Testbed/XP` bed. That bed is an *editor* project:
a loose `Data/` folder, **one** map, **two** event pages, **fifteen** event
commands. Every XP check the repo has was measured against it, and its own ADR
listed "load a packed release" as the obvious next case.

Three things a real released game has that the bed does not:

1. **It is packed.** `Game.ini` + `Game.rgssad` and nothing else; no loose
   `Data/`, no loose `Graphics/`. That is how XP games are actually shipped.
2. **It has more than one map**, so it uses **Transfer Player** — and its start
   map is not where the player spends any time.
3. **It is a whole game.** Pray for You carries 69 maps, 1107 event pages,
   15,797 event commands and 103 script sections, and it is Japanese
   (`RGSS103J.dll`), so it exercises the CP932 text path too.

`scripts/download-prayforyou.bash` already existed in the tree but nothing used
it.

## Decision

Make *Pray for You* a first-class test bed beside the editor project, in every
XP check the repo has, and drive the wine comparison against it.

- **Discovery finds packed projects.** `rpgxp_testbed_check.rb` and
  `rpgxp_script_host_check.rb` globbed for `Data/System.rxdata` /
  `Data/Scripts.rxdata`, which a released game simply does not have on disk.
  Both now also accept a directory holding a `Game.rgssad`.
- **The archive round-trip re-packs the game's own entries.** `check_archive`
  packs the loose `Data/*.rxdata` into a fresh `.rgssad`/`.rgss3a` and loads the
  database back through it. With no loose `Data/` that packed nothing and failed;
  it now reads the `Data/*.rxdata` entries out of the project's *own* archive
  when that is the only copy, so the round-trip still means something.
- **An empty starting party is legal.** The data check demanded a non-empty
  `System.party_members`. Pray for You leaves the editor field blank and adds its
  members from the opening map's autorun event, so the check now asserts only
  that every id it *does* list resolves to a database actor — the thing a
  mis-decoded field would actually break.
- **Both games boot in CI.** `rpgxp_boot_check.bash` defaults to both beds (one
  Xvfb display each, 112 and 113; the RGSSAD packed-asset smoke moves to
  114..115), and the CI download step fetches the game.

## Consequences

Coverage of the *data* layer went from 1 map / 2 event pages / 15 commands to
**70 maps, 1109 event pages, 15,812 event commands**, and of the script host from
90 to 193 decoded sections — with no new harness, only beds the existing checks
can now see.

**Found by booting the real game, and fixed here** — none of these could show up
on a one-map editor project:

- **A Transfer Player left the old map's ground on screen.** The map scene built
  its `Tilemap` once, in `setup_sprites`, and `perform_teleport` rebuilt the map,
  the tileset, the events and the parallels but not the tilemap. Pray for You
  starts on an empty opening map and its autorun teleports to the castle, so the
  game ran with the castle's events and party drawn over map 2's (all-zero,
  black) tiles. RMXP disposes the whole `Spriteset_Map` and makes a new one on a
  transfer; ours now does the same.

**Found by the wine comparison against `RGSS103J.dll`, and fixed here:**

- **Change Screen Color Tone (223) was ignored.** Pray for You tints its entire
  opening dark blue; we rendered it at full brightness, which made *every* map
  pixel differ. The map scene now keeps its ground, the party and the event
  sprites in one screen-sized viewport (RMXP's `Spriteset_Map` `@viewport1`) and
  eases that viewport's tone toward the command's target over its duration —
  which is also why the message box above it keeps its own colours, exactly as
  in the reference frame.
- **The message box was the wrong size and in the wrong place.** Ours spanned
  the full screen width at the very bottom (the RPG2000 layout it had inherited);
  RMXP's `Window_Message` is `super(80, 304, 480, 160)` with its text at x=4 of
  the contents.

Measured on the same map frame, against the genuine runtime:

| | differing pixels (of 307,200) |
| --- | --- |
| before | 298,738 (97%) |
| + tilemap rebuilt on teleport | *the map draws at all* |
| + screen tone | 104,549 (34%) |
| + message-box geometry | 75,695 (25%) |

What is left is dominated by the **reference**, not by us: RGSS finds no font in
the wine prefix, so its message box draws no text at all while ours draws the
game's Japanese lines (the same limitation ADR 0025 measured on the title
screen). The rest is the windowskin background's shading.

**Follow-ups this opens:**

- The event-command histogram over the whole game shows the commands a real XP
  game leans on that we still skip: `221`/`222` (prepare/execute transition, 419
  each), `210` (wait for move completion, 373), `231`/`235` (show/erase picture,
  235 and 234), `224`/`225` (screen flash/shake), `202` (set event location),
  `203` (scroll map), `207` (show animation), `208` (change transparency) and
  `355` (script). Each is now measurable against the reference.
- The `newgame` step of the comparison is not a fair diff: the two runtimes reach
  the opening fade at different moments, so the step compares a black reference
  frame against our already-faded-in one. A save-resume comparison of a fixed map
  (the RPG2000 side's `compare-nepheshel-save-wine.bash` trick) would remove the
  timing from the measurement.
- The browser check still loads only the unpacked bed; the packed game is now the
  obvious second case there too.
