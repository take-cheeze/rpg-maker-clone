# MZ test-bed (`data/mz-sample`)

A tiny, fully-controlled RPG Maker **MZ** project used to exercise the MZ path
(`mruby-mvjs`, class `MZ`) — the embedded quickjs host running the real
`rmmz_*` engine and PIXI v5 on the native surfaceless-EGL WebGL backend
(`mruby-mvjs/src/mvgl.cxx` / `mvwebgl.cxx`, ADR 0004 M6.3).

## What is committed vs fetched

Only our **authored, non-copyrighted** project files live in git, and they are
generated — run `python3 scripts/gen-mz-sample.py` to rewrite them (it is
deterministic, so re-running is a no-op in git):

- `data/*.json` — a database with one actor/class/skill/state, a tileset, a
  `MapInfos` entry and a walled 17×13 start map holding a parallel test event,
  plus a `System.json` with the fields MZ's boot reads (`advanced`, real terms,
  the start position). Authored to match the MZ schema; validated by booting the
  real corescript under Node against the WebGL wrapper's method surface.
- `img/**` — hand-encoded PNGs (no image library): a windowskin with the text
  colour table, the button sheet, an icon sheet, a two-tile A5 tileset and the
  party's walk sheet. Two of these are **not optional** for MZ:
  `img/system/ButtonSet.png` must be at least 11 × 48 px wide or
  `Sprite_Button.checkBitmap` throws ("ButtonSet image is too small") in every
  scrollable window, and `img/system/Window.png` is what `ColorManager` samples
  the text colours from.
- `index.html`, `js/plugins.js` — the shell and an empty plugin list.

`ruby scripts/mz_testbed_check.rb data/mz-sample` validates all of the above
(and any real MZ project) with no build and no JS engine; it runs as a blocking
CI step.

The **engine is not committed**. `scripts/download-mz-corescript.bash` fetches
the RPG Maker MZ corescript (`js/rmmz_*.js`, `js/main.js`, `js/libs/pixi.js` and
the other libraries) into `js/` at build time — the same arrangement as
`data/mv-sample` and the RPG2k/XP test-bed games. See `.gitignore`.

Unlike MV — whose corescript is KADOKAWA's official MIT release
(`rpgtkoolmv/corescript`) — MZ has no official open-source engine. We fetch a
community mirror (`stak/rmmz-corescript`); the rmmz engine is © Gotcha Gotcha
Games / KADOKAWA and is used here only as a fetched, uncommitted **CI test
fixture**, exactly like the proprietary games the other beds download. It is
never redistributed by this repository.

## Running it

```
scripts/download-mz-corescript.bash          # fetch the engine into js/
./build/rpg_maker_clone --game_dir data/mz-sample
```

The maker is auto-detected from `js/rmmz_core.js` + `data/System.json`
(`MZ::REQUIRED_MARKERS`). With the WebGL backend compiled in, the game boots
through `Scene_Boot` to the **title screen** and presents frames on-screen; add
`--mz_new_game --mz_move_test` to advance into the start map and walk the
player without any input, which is what `scripts/mz_boot_check.bash` asserts in
CI (`--mz_screenshot=<path>` captures the frame).

The other in-game paths have probes of their own — `--mz_message_test`,
`--mz_menu_test`, `--mz_save_test` and `--mz_battle_test=1` (the bed's only
troop) — each reached through the boot check's `MZ_MODE`:

```
MZ_MODE=battle scripts/mz_boot_check.bash
```
