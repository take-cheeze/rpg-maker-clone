# MZ test-bed (`data/mz-sample`)

A tiny, fully-controlled RPG Maker **MZ** project used to exercise the MZ path
(`mruby-mvjs`, class `MZ`) — the embedded quickjs host running the real
`rmmz_*` engine and PIXI v5 on the native surfaceless-EGL WebGL backend
(`mruby-mvjs/src/mvgl.cxx` / `mvwebgl.cxx`, ADR 0004 M6.3).

## What is committed vs fetched

Only our **authored, non-copyrighted** project files live in git:

- `data/*.json` — a minimal database (one actor/class/skill/state, a 17×13 start
  map, and a `System.json` with just enough fields for `Scene_Boot` to boot).
  Authored to match the MZ schema; validated by booting the real corescript
  under Node against the WebGL wrapper's method surface.
- `index.html`, `js/plugins.js` — the shell and an empty plugin list.

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
(`MZ::REQUIRED_MARKERS`). With the WebGL backend compiled in, the boot reaches
`Scene_Boot` — `Utils.canUseWebGL()` passes, `Graphics` creates the PIXI
renderer, and `SceneManager.run(Scene_Boot)` runs without hitting the old WebGL
wall.
