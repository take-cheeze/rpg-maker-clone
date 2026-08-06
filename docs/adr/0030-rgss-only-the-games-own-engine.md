# 30. RGSS: run only the game's own engine

Date: 2026-08-05

## Status

Accepted — removes the RPG Maker XP reimplementation of
[ADR 0010](0010-rpgxp-rgss-data-layer.md) and the fallback clause of
[ADR 0029](0029-rgss-script-host-by-default.md).

## Context

This project brought RPG Maker XP up twice.

**First as a reimplementation** (ADR 0010): `mruby-rpgxp` grew its own title
screen, map scene, event interpreter, party/actor model and save format, written
against the database and modelled on how the RPG2000 runtime was staged. It
worked — it booted a project to a walkable map, handled every event command a
real game uses (ADR 0027), drew pictures, animations, transitions and screen
effects, and was the thing the wine comparison measured pixel-for-pixel
(ADR 0025). About 4,600 lines.

**Then as the game's own engine** (ADR 0017, 0023, 0029): the script host
evaluates a project's `Data/Scripts.rxdata` the way `RGSS104E.dll` does. Once the
missing pieces were supplied — the RGSS standard library the player ships
(`RPG::Sprite`, `RPG::Weather`, `RPG::Cache`), `Errno`, `Kernel#Integer`/`#rand`,
`Bitmap#draw_text`'s Rect form, `#clone` on the value types, and an input path a
game's own scene loop can actually read — both test beds ran their *own* engines:
the editor bed onto its map, and the released *Pray for You* through its own
`Scene_logo → Scene_Title → Scene_Map`.

That leaves two engines for one maker, and they are not equals:

- The reimplementation can only ever reproduce the **default** scripts. Every
  game that is worth running replaces some of them — a custom menu, a custom
  battle system, one of the ubiquitous community add-ons — and for those it does
  not run the game, it runs something that resembles it.
- It is a permanent second cost: every RGSS behaviour has to be understood once
  for the class library a game's scripts call, and again for the reimplementation
  that stands in for those scripts. The two drift, and the drift is invisible —
  the reimplementation is only ever compared against itself.
- Keeping it as a *fallback* is worse than not having it: when a game's own
  scripts stop, falling back quietly lands the player in a different engine that
  looks like the game and is not, and it hid exactly that failure in CI until the
  boot check learned to fail on the fallback line.

## Decision

Delete the reimplementation. An RPG Maker XP project runs its own scripts or it
does not run.

- **Removed**: `mruby-rpgxp/mrblib/game.rb`, `scene.rb`, `interpreter.rb` (the
  title/map scenes, the party/actor/state model, the event interpreter, the
  portable save), the tests that covered them, and `--rpgxp_new_game`, whose only
  job was driving that title screen.
- **`RPGXP` is now a boot shell**: read `Game.ini`, load the database, register
  the archive, hand the scripts to the host, drive its Fiber. A project that
  ships no scripts — or a boot with `--norgss_script_host` — reports that there is
  nothing to run rather than being played by a stand-in.
- **A failure inside a game's scripts ends the run**, reported with the section
  and line it came from. There is nothing to fall back to, which is the point:
  the report is the bug list for the class library.
- **The checks now measure the real thing.** `scripts/rpgxp_boot_check.bash`
  taps confirm on each game's own title screen and asserts it reaches a second
  scene, then walks the party on the editor bed's map
  (`--rgss_host_move_test`, `[RPGXP-HOST-MOVE]`). `scripts/rgssad_asset_check.bash`
  keeps its A/B — the same project packed with and without its title graphic —
  but the graphic is now loaded by the game's own `Scene_Title` through
  `RPG::Cache`, whose "did not load" line is what the two runs differ by.
  `scripts/compare-rpgxp-wine.bash` drives both runtimes with the same keys, so
  it now diffs the game's own engine against the genuine one — which is what a
  render comparison should have been measuring all along.

## Consequences

- **One engine, and it is the game's.** Every RGSS behaviour is now understood
  once, in the class library a game's scripts call. Work there is measured by
  games getting further, not by a stand-in agreeing with itself.
- **The bar moved up, visibly.** "Boots" used to mean the reimplementation drew a
  map. It now means a game's own `Scene_Title` took a keypress and its own
  `Game_Player` walked its own passability. The failures that surface are real
  gaps in the class library, each naming the script and line that hit it.
- **What was lost.** The reimplementation was the only thing that could run a
  project shipping no scripts (an editor project mid-authoring), and it was a
  worked reference for how RMXP's default engine behaves — useful reading. Both
  are recoverable from git history if a reason appears; neither is worth the
  standing cost of a second engine.
- **The RPG2000/2003 runtime is untouched.** LCF games ship no scripts at all —
  there is nothing to run but a reimplementation, which is why `mruby-rpg2k`
  exists and stays. This decision is about makers whose games *are* their scripts:
  XP, VX and VX Ace (the VX side never had a built-in flow to remove).
- **Follow-up.** `docs/rpgxp-rgss-api-gap.md` is now the whole XP roadmap: the
  open item is whatever the next boot check reports. (`Bitmap#clone` and
  `Graphics.transition` with a transition image, the two named here when this was
  written, are both closed.)
