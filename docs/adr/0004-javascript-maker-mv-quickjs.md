# 4. JavaScript RPG Maker (MV) support via an embedded QuickJS runtime

Date: 2026-07-24

## Status

Accepted

## Context

The runtime already targets two RPG Maker families: the LCF-based makers
(RPG Maker 2000/2003, via `mruby-lcf` + `mruby-rpg2k`) and the RGSS-based
makers (RPG Maker XP/VX/VXAce, via `mruby-rgss` + `mruby-rpgxp`). The remaining
mainstream family is the **JavaScript-based** one — **RPG Maker MV** and
**MZ** — which is architecturally different from everything supported so far:

| Family            | Data format            | Game logic                         |
| ----------------- | ---------------------- | ---------------------------------- |
| RPG Maker 2000/03 | LCF binary (`*.ldb/lmu`) | reimplemented in `mruby-rpg2k`    |
| RPG Maker XP/VX   | RGSS marshaled + Ruby  | RGSS runtime (`mruby-rgss`)        |
| **RPG Maker MV/MZ** | **JSON** (`data/*.json`) | **JavaScript** (`js/*.js` + PIXI.js) |

There are two ways to run an MV/MZ game:

1. **Reimplement the runtime** in mruby/C++ against the JSON data (the approach
   `mruby-rpg2k` took against LCF). Cheaper to start, but every community plugin
   is JavaScript, so a reimplementation can never run the long tail of plugins
   real games depend on.
2. **Embed a real JavaScript engine** and run the game's own JavaScript
   unmodified, providing the browser/host environment it expects. Larger up
   front, but it runs the actual engine *and* its plugins.

We chose **approach 2** for maximum compatibility. Within it, the rendering
path forces an ordering decision:

- **MV** can drive PIXI.js through its **Canvas2D renderer**, which maps
  naturally onto the blit primitives `mruby-rgss::Bitmap` already exposes
  (`blt`, `stretch_blt`, `fill_rect`, `draw_text`).
- **MZ** ships PIXI v5, which is **WebGL-only** (no Canvas2D fallback) and would
  require a WebGL-subset backend on top of LVGL before anything renders.

So MV-via-Canvas2D is by far the shortest path to a booting, rendering game,
and the engine/host/shim foundation it needs is exactly what MZ will reuse
later.

## Decision

Add a new C++ mrbgem, **`mruby-mvjs`**, that embeds **[quickjs-ng]** (the
actively maintained QuickJS fork) and hosts an unmodified RPG Maker MV game. It
sits beside the existing maker gems and is selected by `src/main.cxx` the same
way RPG2k/RPGXP are — by sniffing the game directory (an MV project has
`js/rpg_core.js` and `data/System.json`).

[quickjs-ng]: https://github.com/quickjs-ng/quickjs

The gem is layered so each concern can land and be reviewed independently:

```
          MV game's own JavaScript  (js/rpg_core.js … js/main.js, plugins)
                        │  runs unmodified inside …
        ┌───────────────▼─────────────────┐
        │   quickjs-ng runtime (C, vendored │  3rd/quickjs
        │   as a submodule, static-linked)  │
        └───────────────┬─────────────────┘
                        │  host globals provided by the shim layer:
   window / document / navigator / location / requestAnimationFrame /
   setTimeout / XMLHttpRequest / Image / AudioContext / localStorage /
   require('fs'|'path')   (a JS "polyfill" preamble + C bridges)
                        │  the drawing + input + IO bridges call into …
        ┌───────────────▼─────────────────┐
        │        mruby-rgss engine         │  Bitmap / Sprite / Graphics /
        │  (LVGL-backed; SDL + terminal)   │  Input / Audio, already present
        └──────────────────────────────────┘
```

Key bridges:

- **Canvas2D → Bitmap.** A `CanvasRenderingContext2D` shim translates the subset
  PIXI's Canvas renderer uses (`drawImage`, `fillRect`, `clearRect`, `get
  ImageData`/`putImageData`, `globalAlpha`, transforms) into `mruby-rgss::Bitmap`
  blits. The final on-screen canvas is one `Sprite` whose `Bitmap` is presented
  every frame.
- **Event loop.** MV drives itself with `requestAnimationFrame`. The rAF/timer
  queue is pumped once per host frame from `MV#main_loop`, interleaved with
  `Input.update` / `Graphics.update`, so the JS game shares the existing
  fixed-cadence loop instead of owning the process.
- **Input.** `mruby-rgss::Input` state is surfaced to MV's `Input` and
  `TouchInput` globals (keymap + a synthetic pointer), so the same
  arrows/WASD/Z/X bindings work as in the other makers.
- **Asset & data IO.** `XMLHttpRequest`/`fetch` for `data/*.json` and images are
  serviced from the game directory (honouring the same directory conventions as
  the other makers); MV's NW.js `require('fs')`/`require('path')` save path is
  shimmed onto host file IO.
- **Audio.** A Web Audio shim maps `AudioContext`/`WebAudio` onto
  `mruby-rgss::Audio`, which is still a stub today — real playback rides along
  with the native audio backend work already tracked in `docs/TODO.md`.

The Ruby side (`mruby-mvjs/mrblib/mv.rb`) stays deliberately **thin**: it detects
the project, knows the canonical MV script load order, and orchestrates the
boot handshake and per-frame pump. It intentionally does *not* parse or model
game data in Ruby — that would drift back toward approach 1. The game's own
JavaScript loads and interprets the JSON.

### Roadmap (each milestone is independently CI-verifiable)

- **M1 — Foundation (this change).** The `mruby-mvjs` gem skeleton, MV project
  detection wired into `src/main.cxx`, the canonical script load order, the
  boot/pump handshake with a clearly-marked seam where the JS host plugs in, and
  host-runnable specs for the pure logic. No JS engine yet, so pointing the
  binary at an MV game reports that the runtime is pending rather than
  misbehaving.
- **M2 — Engine host.** Vendor quickjs-ng as `3rd/quickjs`, static-link it, and
  expose a minimal `MV::JS` (open runtime, evaluate a script, marshal a few
  value types). Verified by a spec that evaluates JavaScript and checks results.
- **M3 — Boot to title.** The host-global polyfill preamble + C bridges, the
  XHR/asset IO bridge, and the rAF/event-loop pump — enough to load the MV core
  scripts and reach `Scene_Title` (logic, not yet pixels).
- **M4 — Rendering.** The Canvas2D→`Bitmap` bridge behind PIXI's Canvas
  renderer; the title screen and map actually draw through `mruby-rgss`.
- **M5 — Play.** Input + save/load (`require('fs')` shim) + audio wiring; a
  walkable MV game in the SDL window and the sixel/iTerm2 terminals.
- **M6 — MZ.** A WebGL-subset backend on LVGL so PIXI v5 / RPG Maker MZ runs on
  the same foundation. Broken into sub-milestones:
  - **M6.1 — Foundation (landed).** An `MZ` class (`mruby-mvjs/mrblib/mz.rb`)
    that detects an MZ project (`js/rmmz_core.js` + `data/System.json`) and
    knows the canonical `rmmz_*` load order, wired into `src/main.cxx`'s maker
    sniff. When the binary is pointed at an MZ game it reports the pending
    WebGL backend cleanly instead of the "no project found" error. Covered by
    host specs (`mruby-mvjs/test/mz_test.rb`).
  - **M6.2 — Host reuse.** Drive the shared quickjs host / host-globals / IO /
    input / audio bridges (all maker-agnostic) with the `rmmz_*` scripts, so an
    MZ game reaches `Scene_Boot` in logic (no pixels). A committed MZ sample is
    authorable the same way `data/mv-sample` is: MZ's corescript has an MIT
    community reimplementation ([stak/rmmz-corescript]), fetched (never
    vendored) like the MV corescript, so no proprietary engine is redistributed.
  - **M6.3 — WebGL rendering.** The WebGL-subset backend behind PIXI v5, the
    bulk of the work — MZ dropped the Canvas2D renderer the MV bridge targets.

[stak/rmmz-corescript]: https://github.com/stak/rmmz-corescript

## Consequences

**Easier / unlocked.** Running an MV game means running its *actual* engine and
plugins, so behaviour matches the editor and the community plugin ecosystem is
in reach — something a Ruby reimplementation could never fully achieve. The
engine, host-global, IO, input and audio layers are all reusable for MZ, so M6
is mostly the WebGL backend rather than a second runtime.

**Harder / costs.** Embedding a JS engine adds a C dependency (quickjs-ng) and a
non-trivial surface of browser/host shims to build and maintain; the Canvas2D
bridge must be faithful enough for PIXI. MZ needs WebGL, which is a large
separate effort (M6). Performance of a Canvas2D path under an embedded
interpreter is unproven and may bound how heavy a game runs acceptably,
especially in the terminal backends. Because the full SDL/mruby binary can't be
built in every development environment, milestones are sized to keep as much
logic as possible behind host-runnable specs, with the native/WebGL-dependent
parts verified in CI and native builds.
