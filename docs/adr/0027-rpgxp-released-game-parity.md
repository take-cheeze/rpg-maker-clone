# 27. Testing RPG Maker XP against a released game (Pray for You)

Date: 2026-08-05

## Status

Accepted — the data, script-host and boot checks run green on both the
OpenGame.exe test bed and the packed *Pray for You* release; the wine comparison
stays a manual/dev script, as in ADR 0021 / 0025.

**Amended 2026-08-05: the picture layer, the message pause arrow and the screen
effects (transitions, flash, shake) landed**, and
`scripts/compare-rpgxp-wine.bash` grew a `STEPS_SPEC` override so a game's
opening cutscene can be driven instead of only its start map. See the follow-ups
below for what that closed and what it did not.

## Context

ADR 0025 set up cross-runtime testing for RPG Maker XP — the native binary and
the genuine `RGSS10*.dll` under wine (and, until that ADR was amended, the
browser build) — but pointed all of it at one project: the `OpenGame.exe`
`Testbed/XP` bed. That bed is an *editor* project:
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

**Found by playing the game further, and fixed here (and, from the amendment, later):**

- **Wait for Move's Completion (210) had no handler** — the third most common
  command in the game after text and move routes (373 uses). The list ran
  straight on, so an event delivered its line before it had finished walking
  over. The interpreter now suspends on it, and the map scene drives the forced
  routes while it waits: `step_events` refuses to move anything while an event
  process is running (that is what holds the map still during a message), so a
  route the interpreter is suspended *on* has to be stepped from the wait
  itself, which is what RMXP does too. A repeating forced route never completes
  — waiting on one hangs RMXP as well — so the wait is bounded and logs why it
  gave up rather than freezing a headless run.
- **Set Event Location (202) and Change Transparent Flag (208) had no handler**
  (86 uses between them). 202 snaps a character onto a tile — direct, from a
  pair of variables, or exchanging places with another event — carrying the
  leader's mid-step bookkeeping with it so it cannot glide back to where it was
  walking. 208 stops the leader being drawn, which is how a cutscene hands the
  hero's tile to an event that looks like him; it is part of the saved state.
- **Ten of the game's music tracks were unplayable.** The boot logged
  `Audio: no BGM found for "tr17memories"` while `Audio/BGM/tr17memories.MID`
  sat right there: `RGSS::Audio::EXTS` tried only lower-case extensions, a hit
  on the Windows these games were authored on and a miss on a case-sensitive
  filesystem. That one folder mixes ten `.MID` with eight `.mid`. Both the disk
  and the archive search now try either case — fixed here even though it is in
  the shared audio resolver rather than the XP runtime, because every maker has
  the same problem with the same real-world data.

- **The message box drew no pause arrow.** RGSS blits the "press on" marker from
  the windowskin's 32x32 block at (160, 64), cycling its four 16x16 frames,
  centred on the bottom edge of a window whose `pause` is set — which
  `Window_Message` sets on every held text box and clears for a choice. The
  reference draws it in every message frame; ours did not.

**Follow-ups this opens:**

- **The picture commands are done** (231 Show, 232 Move, 233 Rotate, 234 Change
  Tone, 235 Erase — 471 uses in this game, and its whole opening is a picture
  cutscene). A `Game::Picture` per slot mirrors `Game_Picture`, easing position,
  zoom, opacity and tone with RMXP's own weighted average, and the map scene
  mirrors the list into sprites in a viewport between the map and the windows —
  the same layering `Spriteset_Map` gets from `@viewport2`. RGSS's `ox`/`oy` are
  not wired to where a sprite draws here, so a centred origin is folded into the
  position instead, scaled by the zoom.
- **The screen effects are done too**: Prepare / Execute Transition (221/222)
  and Screen Flash / Shake (224/225), 871 uses between them. The transition
  question — `Graphics.transition` blocks and drives its own frames, which does
  not compose with being called from inside the scene's update — resolved by not
  calling it: the interpreter suspends on 222 the way it does on a Wait, and the
  scene fades the frozen still one frame per update. That is the same ordering
  RMXP gets from blocking (its scene is not updated during the twenty frames
  either) without a twenty-frame loop inside one frame callback. Only the
  foreground interpreter freezes the screen: a background process is never
  suspended on a UI request, so its 222 would never dissolve the still and the
  screen would stay stuck on a snapshot for good.
- Still no handler: `203` (scroll map), `207` (show animation) and `355`
  (script). 207 needs the animation system; 355 needs a decision about what a
  game's inline Ruby should be evaluated against.
- **Driving the reference past the opening needs 32-bit GStreamer.** Pray for
  You's opening plays MP3 BGM, and `RGSS103J.dll` decodes it through
  winegstreamer; without `gstreamer1.0-plugins-base:i386` (and friends) in the
  container the genuine runtime logs `failed to create decodebin` and its window
  goes black, so every frame past that point compares against nothing. Installing
  them is what makes a cutscene comparison possible at all.
- **This release's own data has a broken asset reference.** `Audio: no SE found
  for "斬る8"` is not ours to fix: the `.rxdata` holds that name as UTF-8 while
  the file on disk is CP932 (`斬る8.wav` in Shift-JIS bytes), so the two cannot
  match on any filesystem. The game was repackaged (see its
  `readme_OhisamaCraft.txt`); the genuine runtime cannot resolve it either. Ours
  logs the miss and carries on, which is the right behaviour.
- The `newgame` step of the comparison is not a fair diff: the two runtimes reach
  the opening fade at different moments, so the step compares a black reference
  frame against our already-faded-in one. A save-resume comparison of a fixed map
  (the RPG2000 side's `compare-nepheshel-save-wine.bash` trick) would remove the
  timing from the measurement.
- If the browser leg comes back (ADR 0025 was amended to drop it), this packed
  release is the case it should load through the page's own loader — a
  `Game.ini` + `Game.rgssad` zip takes a different path through it than a loose
  `Data/` tree.
