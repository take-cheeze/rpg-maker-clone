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
  - **M6.2 — Host reuse (landed, to the WebGL wall).** Drive the shared quickjs
    host / host-globals / IO / input / audio bridges (all maker-agnostic) with
    the `rmmz_*` scripts. `MZ#boot_probe` (`mruby-mvjs/mrblib/mz.rb`) now loads
    every engine script and calls `SceneManager.run(Scene_Boot)`, which reaches
    exactly the WebGL guard below and stops there — everything up to the
    renderer works. Unlike MV, there is **no committable/fetchable MZ test
    bed**: MV's corescript is an official open-source project ([rpgtkoolmv],
    MIT, redistributed by KADOKAWA) that `data/mv-sample` fetches, but MZ's
    engine ships only with the paid editor (© Gotcha Gotcha Games / KADOKAWA)
    and has no equivalent open-source release — the GitHub mirrors of it (e.g.
    `stak/rmmz-corescript`) carry no license. So this path is developed and
    verified against a **user-supplied** MZ project, not a downloaded engine
    (the same constraint the RPG2000/XP beds hit for their non-redistributable
    assets), and cannot run in CI; the pure logic it leans on
    (`MZ.runnable_scripts`, `MZ.host_globals_js`) is covered by host specs
    instead.
  - **M6.3 — WebGL rendering.** The WebGL-subset backend behind PIXI v5, the
    bulk of the work — MZ dropped the Canvas2D renderer the MV bridge targets.
    The renderer is a **surfaceless EGL** context (Mesa's llvmpipe over
    `EGL_MESA_platform_surfaceless`) driving the **GLES2** entry points, wrapped
    as WebGL. It renders into an FBO read back to a CPU RGBA buffer with no GPU
    or display — the same software model as the LVGL/Canvas2D paths — so it works
    identically in the SDL window, the terminals and headless CI. GLES2 is the
    right target because PIXI v5's WebGL1 shaders are GLSL ES 1.00, which Mesa's
    compiler accepts verbatim: **no shader-translation layer is needed** (contrast
    ANGLE, which targets a native GPU API and would need SwiftShader underneath
    to run GPU-less — heavier, for no fidelity gain on a software target). This
    began on **OSMesa**, but Mesa removed the OSMesa frontend (gone from mesa
    26.1, so nixpkgs 26.05 ships no `libOSMesa`); surfaceless EGL is its
    supported off-screen replacement and, unlike OSMesa, is available from stock
    Mesa on both apt and nix.
    - **M6.3a — GL foundation (landed).** `mruby-mvjs/src/mvgl.cxx` creates a
      surfaceless EGL GLES2 context with an FBO render target, exposed to Ruby as
      `MV::GL`. A self-test (`MV::GL.smoke_test`) compiles the PIXI-style ES 1.00
      shaders, draws and reads a pixel back, pinned by
      `mruby-mvjs/test/gl_test.rb` — the one part of M6.3 that can be exercised
      without the proprietary MZ engine. The backend is **build-optional**:
      `mvgl.cxx` compiles to inert stubs (an `__has_include` guard) and
      `MV::GL.available?` reports false where the EGL headers are absent, so the
      CMake link and the gem test only pick it up where the libraries exist. It
      is verified on the apt-based dev build (`libegl1-mesa-dev`/
      `libgles2-mesa-dev`) and on the nix/CI build (`flake.nix` adds `libglvnd`
      for the EGL/GLES2 headers and dispatch, and `mesa.llvmpipeHook` for the
      headless software-GL runtime), so `MV::GL.smoke_test` runs as a CI check.
      The Emscripten build stubs it (it renders MZ through the browser's own
      WebGL).
    - **M6.3b — WebGL wrapper (landed).** `mruby-mvjs/src/mvwebgl.cxx` maps the
      `WebGLRenderingContext` surface onto the native GLES2 backend (the
      `__mv_gl*` natives + the `WebGLRenderingContext` prototype), so
      `canvas.getContext("webgl")`/`"experimental-webgl"` returns a real,
      native-backed context instead of `null` and `Utils.canUseWebGL()` becomes
      true. WebGL objects are their GL integer names; `bindFramebuffer(_, null)`
      targets the context's own FBO (a surfaceless context has no default
      framebuffer). `gl_test.rb` drives a green triangle end to end through the
      wrapper (compile ES 1.00 shaders → buffer → draw → `readPixels`), the
      JS-layer proof of the same pipeline `MV::GL.smoke_test` exercises natively.
      Where the EGL backend is absent (Emscripten/darwin) the natives are not
      installed and `getContext("webgl")` stays `null`, so PIXI keeps its Canvas
      path there.
    - **M6.3c — PIXI v5 boots to a frame (reaches Scene_Boot).** `data/mz-sample`
      commits a minimal authored database and fetches the rmmz engine (community
      mirror `stak/rmmz-corescript`, CI-only fixture) via
      `scripts/download-mz-corescript.bash`. The one host global MZ's boot needs
      beyond MV's — `indexedDB` (the `SceneManager.checkBrowser` guard after
      `Utils.canUseWebGL`) — is added to `MZ::HOST_GLOBALS_JS`, and `MZ#boot_probe`
      drives `SceneManager.run(Scene_Boot)` plus a few frames past the old WebGL
      wall: `Graphics` builds the PIXI renderer on the surfaceless-EGL backend and
      the scene runs. `scripts/mz_boot_check.bash` asserts the `[MZ-BOOT]` marker
      in CI. The gap set was found by booting PIXI v5.2.4 + rmmz under Node
      against the wrapper's method surface — the single wrapper fix it required
      was the enum statics (above); VAO/instancing are feature-detected and fall
      back cleanly.
    - **M6.3c (cont.) — title screen and a walkable map.** Reaching a *playable*
      scene took three fixes, again found by driving PIXI v5.2.4 + rmmz under
      Node with the host's own semantics:
      1. **The frame is the pump, not `SceneManager.update`.** MZ hands its loop
         to PIXI's ticker (`SceneManager.run` → `Graphics.startGameLoop`), and
         only `Graphics._onTick` — reached through `requestAnimationFrame` — both
         updates the scene and calls `_app.render()`. `MZ#main_loop` used to call
         `SceneManager.update` itself, which rendered nothing and left every
         promise microtask and rAF callback queued, so `Scene_Boot` (a *loading*
         scene polling `ImageManager`/`FontManager`/`ConfigManager`/
         `StorageManager` across frames) could never become ready. `MZ#pump_frame`
         now advances the host once per frame, exactly as the MV path does, and
         `#boot_probe` pumps until the boot scene hands over.
      2. **`HTMLImageElement` must be the host's `Image`.** PIXI v5 decides how to
         wrap a texture source with `source instanceof HTMLImageElement`; a
         separate empty shim made that false, so PIXI built a fresh image and
         assigned our image *object* to its `src` — every bitmap a broken
         texture. The globals now alias the two, which routes uploads through the
         wrapper's `texImage2D(..., src.__h)` canvas/image-handle path.
      3. **The Canvas2D context needed `strokeRect`.** MV never calls it; MZ
         strokes an item-background frame for every row of every selectable
         window (`Window_Selectable.drawBackgroundRect` →
         `Bitmap.prototype.strokeRect`), so the title's command window threw
         `TypeError: not a function` at `rmmz_core.js:1587` on the first drawn
         frame. `mvcanvas.cxx` implements it as four `lineWidth`-thick bars
         through the existing native fill, so the transform, alpha, composite
         mode and colour parsing are shared with `fillRect`. Worth noting *how*
         this was caught: a permissive JS harness stubs every context method and
         therefore cannot see a gap in the native surface — it took the real
         engine (the `[MZ-DIAG]` readiness dump on PR #333's CI run, which showed
         `Scene_Title` with every gate true and the boot dying inside its
         drawing). The dev harness is only trustworthy for this class of bug if
         its context exposes exactly `Ctx.prototype`'s methods and no more.
      4. **The bed must carry MZ's required art and flags.** `Sprite_Button`
         *throws* on a `ButtonSet.png` narrower than 11 × 48 px (MZ's touch UI
         builds those buttons in every scrollable window), and a tileset whose
         `flags[0]` lacks `0x10` ("no effect on passage") makes every cell
         passable, because `Game_Map.checkPassage` lets the first non-"no effect"
         tile from the top layer down decide and the empty upper layers answer
         first. `scripts/gen-mz-sample.py` authors both (plus a windowskin, icon
         sheet, tileset, party sprite, a walled room and real terms), and
         `scripts/mz_testbed_check.rb` is the blocking CRuby guard for them.
      With those, `--mz_new_game`/`--mz_move_test` boot the bed to `Scene_Title`,
      start a New Game and walk the player on the start map headlessly in CI,
      and `--mz_screenshot` captures the frame (`MV::JS.screenshot_gl`, the FBO
      counterpart of MV's canvas capture). Remaining: FBO resize on a PIXI canvas
      resize, an MZ audio bridge (MV's `AudioManager` → `RGSS::Audio` route is
      not wired for MZ yet) and `.woff` font loading, all verified against a real
      MZ project.

  **Concrete boot map (verified by running the engine on the host).** MZ's boot
  differs from MV's in more than the renderer. Driving the shared host through a
  real MZ project (`MZ#boot_probe`) turned the earlier source-read guesses into
  a measured map — in the order the engine hits it:
  1. **Script loading — solved by driving the order directly.** MV registers
     `window.onload` and the host evals `CORE_SCRIPTS` then fires it. MZ's
     `main.js` is itself the loader: it appends the other scripts as `<script>`
     elements and waits for their `onload`. The host reuse evaluates
     `MZ.runnable_scripts` (CORE_SCRIPTS minus `main.js`) in order instead of
     eval'ing the loader, since our shim does not fetch+execute injected
     `<script>` tags. PIXI v5.2.4 loads and runs fine under quickjs.
  2. **Extra host globals.** `rmmz_managers.js` references `HTMLVideoElement`
     and `HTMLImageElement` at module-load time and fails to define the module
     if they are absent (MV's `rpg_*` never touch them). Empty-constructor
     stubs (`MZ.host_globals_js`) get past module load — the host draws through
     RGSS::Bitmap, not the DOM.
  3. **Effekseer WASM — not on the boot path.** The earlier guess was that
     `main.js` calls `effekseer.initRuntime(…)` and blocks `Scene_Boot` on it,
     needing a WASM shim. Measured: because M6.2 bypasses `main.js`, that
     `initRuntime` call is skipped entirely, and `effekseer.min.js` itself
     loads without WebAssembly (the WASM is fetched lazily, only when an
     animation plays). The one script that *does* need `WebAssembly` at load is
     `js/libs/vorbisdecoder.js`; it is audio-only, so `MZ.runnable_scripts`
     skips it and audio rides the shared RGSS::Audio bridge. No Effekseer stub
     is required to reach a scene.
  4. **The WebGL wall — the sole remaining blocker (M6.3).** With 1–3 handled,
     `SceneManager.run(Scene_Boot)` reaches exactly
     `if (!Utils.canUseWebGL()) throw …` at `rmmz_managers.js:1890` and throws
     (caught by `SceneManager.catchException`); PIXI v5 has no Canvas2D
     fallback. This is M6.3: `canvas.getContext("webgl")` must return a real
     (LVGL-backed) context — the host deliberately keeps it `null` today so
     MV's PIXI v4 uses Canvas. Nothing else stands between the host and a
     rendered MZ frame.

[rpgtkoolmv]: https://github.com/rpgtkoolmv/corescript

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
