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
      Two further gaps showed up only once the real engine ran in CI, both of
      them invisible to the Node harness because it stubbed every method PIXI
      asked for:
      5. **`gl.clearStencil` was missing from the WebGL wrapper.**
         `WindowLayer.render` calls it on every frame that draws a window. The
         resulting `TypeError: not a function` is *fatal* rather than transient:
         PIXI v5 re-arms its `requestAnimationFrame` only after `update()`
         returns, so a single throw inside the ticker stops the game loop
         permanently — which is why the log showed one error and a scene that
         never changed again. Added as a no-op beside the existing stencil
         stubs, with `polygonOffset` and `uniform3i`/`uniform4i` alongside. The
         FBO does carry a packed DEPTH24_STENCIL8 renderbuffer, so what keeps
         `WindowLayer`'s per-window clipping from clipping is only that
         `stencilFunc`/`Op`/`Mask` are still no-ops in the wrapper — mapping
         those three onto GL is all the feature needs.
      6. **The render target was never resized past 1x1.** The context is created
         from a canvas that is still 0x0 and MZ sizes it only in
         `Scene_Boot.resizeScreen` → `Graphics.resize` → PIXI's
         `renderer.resize`. `mvgl::resize` re-specifies both renderbuffers,
         `__mv_glResize` exposes it, and the canvas' width/height setters drive
         it — so the game renders at its real resolution instead of into one
         pixel.

      The lesson worth keeping: **a harness is only as good as its narrowest
      stub.** Both of these, and the `strokeRect` gap above, were bugs in the
      *native* surface that a permissive JS double could never reproduce. The
      harness now mirrors `Ctx.prototype` and `mvwebgl.cxx`'s `P.*` list exactly,
      and reproduces each failure verbatim when the corresponding entry is
      removed.

      With all of it, `--mz_new_game`/`--mz_move_test` boot the bed to
      `Scene_Title`, start a New Game and walk the player on the start map, and
      `--mz_screenshot` captures the frame (`MV::JS.screenshot_gl`, the FBO
      counterpart of MV's canvas capture). The wrapper's `stencilFunc`/`Op`/`Mask` now map onto GL as well, so
      `WindowLayer`'s per-window clipping actually clips (the FBO's packed
      DEPTH24_STENCIL8 buffer had been attached since M6.3a and simply never
      programmed); `gl_test` asserts the masking at the pixel level on the real
      backend. MZ's audio rides the same bridge as MV's
      (`MV::AUDIO_BRIDGE_JS`, drained by `MZ#pump_audio`), plus one MZ-only
      override: `Scene_Boot`'s eager `preloadImportantSounds` reaches
      `AudioManager.loadStaticSe` → `createBuffer` → `new WebAudio`, and MZ's
      `WebAudio` uses **`fetch`** where MV used `XMLHttpRequest` — a global this
      host does not provide, so naming a system sound killed the boot until both
      were neutralised. Remaining: `.woff` font loading (the canvas text loader
      finds only `.ttf`/`.otf`, and MZ games ship `.woff`, so their text draws
      blank), verified against a real MZ project.
    - **M6.3d — the rest of the in-game paths (landed).** Booting and walking is
      not playing, so the four paths the MV side already proves are now driven on
      MZ too, each behind its own launcher flag and each asserted by
      `scripts/mz_boot_check.bash` under an `MZ_MODE`
      (`play`/`message`/`menu`/`save`/`battle`): a message queued through
      `$gameMessage` must open `Window_Message` (`--mz_message_test`),
      `Scene_Map`'s own `callMenu` must reach `Scene_Menu` (`--mz_menu_test`), a
      save must round-trip through the real `DataManager` (`--mz_save_test`), and
      a Battle Processing command run through the map interpreter must land in
      `Scene_Battle` (`--mz_battle_test=<troopId>`). Three things are worth
      recording about how MZ differs from MV here:
      1. **The save path is asynchronous.** MV's `DataManager.saveGame` returns a
         boolean; MZ's returns a promise, and so does everything under it
         (`objectToJson` → `jsonToZip` (pako) → `saveZip` → localforage, and the
         mirror image on load). A probe that reads a return value therefore
         cannot work: `MZ#maybe_save_test` starts the chain and polls a global
         the chain parks its verdict on, one read per pumped frame — the pump
         being what drains the microtasks the chain waits on. It also reads
         `savefileExists` *after* the save resolves, because `saveToForage`
         refreshes `StorageManager`'s key cache only at the end of its own chain,
         and it finishes with `SceneManager.goto(Scene_Map)` the way
         `Scene_Load.onLoadSuccess` does — a load throws the `$game*` objects
         away and rebuilds them, so the running scene has to be rebuilt against
         the new ones rather than left holding the discarded set. A re-entry that
         throws is appended to the verdict, not allowed to overwrite it.
      2. **The menu cannot be reached with a key.** rmmz's keyboard
         `Input.keyMapper` has no `"menu"` binding (only the gamepad's Y), so the
         probe sets `Scene_Map#menuCalling` — exactly what `isMenuCalled` sets —
         and lets `updateCallMenu` run the real `callMenu` inside the scene loop.
         It re-asserts the flag every frame, since `updateCallMenu` clears it on
         any frame the menu is momentarily disabled (the New Game transfer still
         settling right after the map arrives).
      3. **The battle must be started from inside the scene loop**, for the same
         reason as on MV: a bare `SceneManager.push(Scene_Battle)` leaves the map
         active with the encounter effect frozen, because that effect only
         advances while the scene is inactive. rmmz's `command301` takes the same
         `[type, troopId, canEscape, canLose]` parameters as rmmv's, so the
         injected command list is shared in shape with the MV probe.
      No native gap turned up in the *probes*: the battle's encounter effect
      snapshots the screen through `Bitmap.snap` → PIXI's `extract.canvas`, which
      reads the FBO back with `gl.readPixels` and writes it through the canvas
      bridge's `getImageData`/`putImageData` — a path the boot already exercised,
      since `Scene_Title.terminate` snaps for the menu background on every New
      Game. Reading the frames those probes captured is what found the next two.
    - **M6.3e — the frames were empty (landed).** Every probe above passed while
      the captured PNGs were **blank**: the scene graph was right and nothing but
      the tilemap reached the framebuffer. Two calls in the wrapper accepted
      their arguments and threw the pixels away:
      1. **`texSubImage2D` was a no-op.** PIXI re-uploads a texture whose
         dimensions have not changed with `texSubImage2D` rather than
         `texImage2D`, so the *first* upload of a `Bitmap` (usually while it is
         still blank) was the only one that ever reached GL. Everything a game
         paints after that — window contents, rendered text, the tileset pages
         rmmz's `Tilemap` sub-uploads into its 2048×2048 atlas — was dropped.
         Both overloads are implemented now, the sized/typed-array one and the
         canvas/image-source one.
      2. **`bufferData` rejected a bare `ArrayBuffer`.** WebGL's `BufferSource`
         is `ArrayBufferView | ArrayBuffer`; the byte extractor (`view_bytes`)
         handled only views, and PIXI v5's sprite batcher uploads its whole
         interleaved vertex block as the raw `ArrayBuffer` behind its views
         (`ViewableBuffer.rawBinaryData`). The upload silently became
         **zero-length**, so every batched sprite drew from an empty vertex
         buffer: degenerate triangles, no fragments, no GL error. That is
         precisely why the tilemap was the only visible thing — rmmz's `Tilemap`
         is a separate `ObjectRenderer` with its own geometry, uploaded from a
         `Float32Array` view.

      How it was found is worth keeping, because both failures are invisible to
      every check that stops at "did it run": the probes reported success, the
      draws were issued, `glGetError` stayed 0, the shaders compiled and PIXI's
      own attribute wiring (locations, strides, offsets, normalisation) read back
      correct. Forcing the batch fragment shader to emit solid red and seeing
      *nothing* was what proved the fragments never existed, which pointed at the
      vertex stage; logging the actual byte counts at every `bufferData` /
      `bufferSubData` then showed the batcher's vertex uploads going in at
      **0 bytes** while its index uploads went in at 48. The lesson is the same
      one M6.3c drew about stubs, one level further out: **a screenshot nobody
      reads is not evidence.** `mruby-mvjs/test/gl_test.rb` now asserts both at
      the pixel level on the real EGL backend, and each test was checked to fail
      with the fix reverted.

      With both fixed, MZ draws its title screen and command window, the map with
      the player sprite and touch UI, message windows with their text, and the
      party menu over a blurred map background. The battle screenshot waits for
      `Scene_Battle`'s fade-in before capturing; the bed's own battle frame stays
      near-black. That was read at the time as the authored sample shipping no
      battler art or battleback — the same reason MV runs its battle smoke
      against a real downloaded game. **It was the wrong reading**, and M6.3i
      below has the real one: the battle scene was throwing an exception on
      every frame, so the frame was dark because almost nothing in it ran.
    - **M6.3f — the stencil never reached the surface MZ draws on (landed).**
      M6.3c mapped `stencilFunc`/`Op`/`Mask` onto GL so `WindowLayer`'s
      per-window clipping would clip, and proved it on the main FBO — which
      `mvgl.cxx` builds with a packed DEPTH24_STENCIL8 buffer. But **MZ never
      draws a scene into that FBO**: `Scene_Base` puts a `ColorFilter` on every
      scene, so the scene renders into a filter *render texture* and only the
      filter's output quad reaches the main FBO. rmmz's `WindowLayer.render`
      calls `renderer.framebuffer.forceStencil()`, which has PIXI attach a
      stencil renderbuffer to whatever framebuffer is current — and the
      wrapper's five renderbuffer entry points were stubs
      (`createRenderbuffer` returned 0, the rest were no-ops), on the assumption
      that only the main FBO ever needed one. With no attachment the stencil
      test always passes, so every window overpainted its neighbours.

      All five now map onto GL, translating the two WebGL1 enums GLES2 has no
      equivalent for: the combined `DEPTH_STENCIL` internal format becomes
      `DEPTH24_STENCIL8` (the OES_packed_depth_stencil value `mvgl.cxx` already
      uses), and the combined `DEPTH_STENCIL_ATTACHMENT` point becomes an attach
      to *both* `DEPTH_ATTACHMENT` and `STENCIL_ATTACHMENT`, which is what a
      packed buffer feeds. `gl_test` gains a masking case bound to a
      framebuffer whose colour target is a texture and whose depth/stencil is a
      renderbuffer — the arrangement PIXI builds — and it fails with the stubs
      restored.

      The pattern is worth naming, because it is the third time in this
      milestone: **a capability proved on the wrong surface is not proved.** The
      stencil worked where nothing was drawn and was absent where everything is.
    - **M6.3g — the smokes now read the frames (landed).** M6.3e and M6.3f were
      both found by a human looking at pictures, because every automated
      assertion in `scripts/mz_boot_check.bash` reads the engine's *log*:
      `Scene_Map` was reached, `$gameMessage` is busy with `Window_Message`
      open, the save chain settled. A frame can be empty while all of that is
      true. `scripts/mz_frame_check.rb` closes that gap by decoding the captured
      PNGs — a small pure-Ruby reader for the subset `stb_image_write` emits
      (8-bit RGB/RGBA, non-interlaced, all five row filters).

      It asks two kinds of question, because measuring showed that neither kind
      alone is enough:

      * **Per frame, absolute.** The M6.3e frames were not blank — the player
        sprite and the touch-UI button still drew — so a "not a flat fill" floor
        passes on them. What they had lost was the map: 99.5% of the play frame
        was one colour against 68.5% intact. And the message band carries 105
        distinct colours when the window's contents upload against 18 when only
        its skin draws, because antialiased glyphs scatter intermediate colours
        through it.
      * **Across frames, relational.** Each mode's frame against the plain map
        frame from `play`: the message frame differs in the bottom band (93.0%)
        and barely outside it (0.3%), so the change is provably *the window*;
        the menu and battle frames replace the screen (100.0%); the post-save
        frame is the map again (0.2%), so a round-trip that returns to a wrecked
        scene fails.

      The relational half alone would **not** have caught M6.3e — that bug
      degraded every frame identically, so the differences between modes
      survived it intact (the window skin still drew, over a black map). This is
      worth recording because the first draft of the check was relational only,
      and rebuilding with the fix reverted disproved it: every mode still passed.
      The absolute half was added from what that experiment measured, and the
      same experiment is the check's non-vacuity proof — with `texSubImage2D`
      reverted to a no-op, all five `mz_boot_check.bash` modes still report OK
      while the frame check fails on the play frame's dominant colour and the
      message band's colour count.

      Which is the fourth instance of the milestone's pattern, one level up: **a
      test written from a theory of the bug is not a test until the bug is put
      back.**
    - **M6.3h — animations (landed).** The last in-game system with no coverage,
      and MZ has two of them. `Spriteset_Base.isMVAnimation` routes purely by
      data shape:

      ```js
      Spriteset_Base.prototype.isMVAnimation = function(animation) {
          return !!animation.frames;
      };
      ```

      An animation carrying a `frames` array is drawn by `Sprite_AnimationMV` —
      sixteen plain `Sprite` cells indexed out of a 192x192-cell sheet, with
      per-cell position, rotation, scale, opacity and **blend mode**. Everything
      else goes to `Sprite_Animation`, which plays through Effekseer:
      `Graphics._createEffekseerContext` needs `effekseer.createContext()`, and
      the WASM runtime behind it is initialised by `main.js`, which M6.2
      deliberately bypasses. So `Graphics.effekseer` stays null,
      `EffectManager.load` returns nothing, and `Sprite_Animation.update` takes
      its `else` branch — the animation "plays" its sound and flash timings on
      schedule and draws no visuals. That degradation is graceful (nothing
      hangs; `_started` is set so the sprite still ends), and it is *silent*,
      which is the part worth writing down: an MZ project whose animations are
      all Effekseer will look like it is running fine.

      The MV-format path needs nothing we do not already have, and it works:
      `data/mz-sample` gains an authored burst, `--mz_animation_test` requests
      it on the player through `$gameTemp.requestAnimation` (the call Show
      Animation makes), and it draws — including the additive blend the bed's
      last frame asks for, which nothing else in this project exercises. The
      probe re-requests while the map is up so a burst is always on screen, and
      the screenshot waits for a frame with visible cells rather than firing on
      a frame count, or it would photograph the gaps between bursts.

      The animation's cells are all the *same area*, differing only in colour.
      That is not the obvious choice — expanding rings look more like an
      animation — but a smoke test captures one frame at a moment it does not
      control, and rings made the evidence depend on which frame it caught (a
      7x spread between first and last). Equal-area cells make the measurement
      the same 36.2% of the centre box every run.

      It also shows why M6.3g's frame check is not redundant with the log: with
      the animation's sheet renamed away, `[MZ-ANIM]` still reports
      `played=true`, because the cell sprite is visible and carries the host's
      1x1 placeholder bitmap. The log cannot tell a drawn burst from a drawn
      nothing. The frame check fails on it.
    - **M6.3i — the battles were frozen the whole time (landed).** The battle
      smoke asserted `Scene_Battle` was reached, and had been green since
      M6.3d. Writing a probe that *plays* the fight — tap confirm through the
      party command window, the actor command window and the target window,
      then watch the enemy's HP — showed the battle had never worked at all:
      `BattleManager._phase` stayed at `"start"` forever, no window ever opened,
      and no key press had any effect.

      The cause is four lines of rmmz and one field of authored data:

      ```js
      Sprite_Enemy.prototype.initMembers = function() { … this._battlerName = ""; … };
      Sprite_Enemy.prototype.updateBitmap = function() {
          const name = this._enemy.battlerName();
          if (this._battlerName !== name || …) { … this.loadBitmap(name); }
      };
      Sprite_Enemy.prototype.updateFrame = function() {
          … this.setFrame(0, 0, this.bitmap.width, this.bitmap.height);
      };
      ```

      The bed's enemy had `battlerName: ""`, which *equals* the sprite's initial
      value, so the load never fired, `this.bitmap` stayed `undefined`, and the
      next line read `.width` off it. That threw on the first frame of the
      battle and every frame after — and because the throw happens inside
      `Scene_Battle.update`, everything after it was skipped: the window layer
      stopped updating, so the battle-start message never opened or cleared,
      so `$gameMessage.isBusy()` stayed true, so `BattleManager.isBusy()` stayed
      true, so the phase never advanced. A fight dead on arrival, silently.

      This is rmmz's own behaviour, not something the host introduces — a
      browser breaks identically — and the editor never writes an empty
      `battlerName`, so only a hand-authored bed can reach it. Two more fields
      were missing for the same reason: the class and the enemy carried no
      `xparam` HIT trait, and a physical action's chance to connect is
      `successRate * 0.01 * subject.hit` with `hit` defaulting to **0**, so once
      the fight did run, every attack missed and neither side could ever win.
      With a battler image and 95% hit on both sides, the fight resolves:
      100 HP to 0, victory, back to the map.

      Three things are worth keeping from this one:

      * **The smoke was green over a scene that never worked.** "Reached
        `Scene_Battle`" is true the instant the scene is pushed, which is before
        its first update — so it is a claim about scene construction, not about
        combat. The interesting assertion is always the one *after* the thing
        starts.
      * **The frame check's exemption was hiding it.** M6.3g exempted the
        battle frame from the "the scene's art reached the frame" check, on the
        documented reasoning that a bed with no battler art is legitimately
        near-black. That reasoning was inherited from M6.3e's note above and
        never questioned. With the bed fixed, the battle frame is 57.7%
        dominant across 101 colours and takes the same check as every other
        mode — the exemption is gone.
      * **Exceptions inside the frame pump are invisible.** Nothing logged. The
        throw surfaced only by wrapping `SceneManager._scene.update` in a
        try/catch from a probe. Anything that runs inside PIXI's ticker can fail
        silently in this host, which is worth remembering the next time a scene
        looks alive and does nothing.

    - **M6.3j — the menu, actually used (landed).** M6.3i's finding was about a
      *shape* of assertion, not about battles: `[MZ-MENU] reached_menu=true` is
      the same claim `reached_battle=true` was — true the instant the scene is
      pushed, before its first update — and the menu was the last in-game system
      still resting on it. `--mz_menu_play` (`MZ_MODE=menu_play`) uses the menu
      instead: confirm walks `Window_MenuCommand` to Item, the item category,
      the item list and the actor window; then cancel unwinds the stack back to
      the map. It asserts `healed=true used=true returned=true` — an item's
      effect reached an actor's HP, the inventory paid for it, and the menu
      handed the player back.

      **The menu worked.** Unlike the battle, the walk came out right on the
      first run (`hp_before=100 hp_after=200 items_before=3 items_after=2`), so
      this milestone adds coverage rather than a fix. Two things had been hiding
      behind the old assertion anyway:

      * **The bed had no items at all.** `Items.json` was `[null]`, so
        `Scene_Item` opened onto an empty list and there was nothing in the
        project to use, equip or sell. A menu with nothing in it cannot tell a
        working item path from a broken one, which is why the bed now authors a
        Potion (`scope` 7 so the actor window is in the flow, flat `value2`
        recovery so the probe can assert a figure). Running the new mode against
        the old empty bed fails on `healed=true` — while the old `menu` mode
        still reports `reached_menu=true` on that same run, which is the whole
        point.
      * **A healing item is only selectable while someone is hurt**
        (`Game_Action.testApply` → `isItemEffectsValid`), and MZ has no
        starting-inventory field. So the probe arms the party first — Change
        Items and Change HP, run through the *map interpreter* as the event
        commands a real project would use, the same way M6.3i's Battle
        Processing is injected rather than calling `SceneManager.push`.

    - **M6.3j (cont.) — the run budget was in the wrong unit.** Adding the mode
      surfaced a defect in every mode: a probe gives up after so many *frames*,
      the engine after so many *milliseconds* (`--timeout_ms`), and a headless
      software-GL frame costs far more wall clock on a loaded host than on a
      fast one. On this container the battle play-out — green in CI and locally
      at M6.3i — now ran out of wall clock mid-fight, having landed 41 damage
      and cycled several turns, and the check reported **"no attack ever
      damaged an enemy"**: a cut-off run prints no report at all, and the
      absence of the line was being read as the thing under test never
      happening. Exactly the M6.3e/M6.3i failure mode, one layer out.

      Two changes. `MZ#finish_when_probes_done` ends the run as soon as every
      requested probe has reported and the screenshot is taken (raising
      `RGSS::Timeout`, the same path the engine's own budget unwinds through),
      so `--timeout_ms` becomes a true ceiling rather than the running time —
      the eight modes now take 11–116s each instead of a flat 60s, and
      `battle_play` completes where it used to be cut off. The two play-out
      modes then get ceilings sized for the slowest host (180s and 280s), and
      the checks distinguish "the run ended before the fight did" from "nothing
      was damaged" so the message names the real cause.

    - **M6.3k — the save round-trip, verified rather than assumed (landed).**
      The last assertion of the M6.3i shape was the save probe's: `saved=true
      exists=true loaded=true` says the promise chain *settled* — the slot
      deflated, `savefileExists` found it, `loadGame` resolved. All three are
      true of a load that restores nothing, and of one that quietly starts a new
      game instead.

      The probe now moves six fields off their defaults before saving (gold, a
      switch, a variable, an actor's HP, the inventory, the player's position),
      overwrites every one of them *between* the save and the load, and compares
      the state read back afterwards against the state read before. `restored=`
      is that comparison; a mismatch prints both signatures, so the failure
      names the fields that did not come back.

      Arming the fields first is what makes the check real: a fresh game's state
      and an unwritten save's state would both read as the defaults, so a probe
      that saved the defaults could not tell `loadGame` from
      `setupNewGame`. **The round-trip does work** (`restored=true` on the first
      run) — but with `loadGame` stubbed to a resolved promise the old three
      claims all still pass while the new one fails with the diff:

      ```
      [MZ-SAVE] saved=true exists=true loaded=true restored=false
                before=[gold=1234 sw=1 var=4321 hp=289 items=5 pos=3,4]
                after=[gold=2011 sw=0 var=9999 hp=252 items=3 pos=11,9]
      ```

      No new mode: the existing `save` mode's claim gets stronger, which is
      cheaper than a ninth CI step for what is one flow.

    - **M6.3l — leaving the start map (landed).** Every MZ probe up to here ran
      on `Map001`, because the bed only had one map. Everything about arriving
      somewhere else is a separate path and none of it had been executed:
      `Game_Player.reserveTransfer` and the interpreter's `"transfer"` wait mode,
      `Scene_Map` tearing itself down and re-creating, `DataManager.loadMapData`
      fetching a `MapXXX.json` that was never read at boot, a fresh
      `Spriteset_Map` over a different tile layout, and `Game_Map.setupEvents`
      for the arriving map's events.

      The bed gains a second map — a wall cross on open floor, so its frame
      cannot be confused with the first map's bordered room — and
      `--mz_transfer_test` (`MZ_MODE=transfer`) runs a **Transfer Player**
      command (code 201) through the map interpreter, the way a game leaves a
      map. Three claims of increasing strength: `moved=` (the map id changed),
      `landed=` (the player is on the requested tile) and `arrived=` — the
      *destination's own* parallel event having run, which is the difference
      between the id moving and the map having been fetched, built and set
      running. The frame check gains the matching picture claim (the arrival
      frame differs from the start map by 35%, measured).

      **The transfer worked; the bed's authoring did not.** The first run came
      back `moved=true landed=true arrived=false`: map 2 had loaded and its one
      event was there, but the variable that event writes never moved.
      `Game_Variables.setValue` silently ignores any id at or past the length of
      `$dataSystem.variables`, and the bed declared exactly one variable while
      map 2's event wrote the second. No error, anywhere — the same shape as the
      empty `battlerName` of M6.3i and the empty `Items.json` of M6.3j: a
      hand-authored bed can hold values the editor would never write, and the
      engine's response is silence rather than a complaint. The bed now declares
      both variables.

    - **M6.3m — common events, both kinds (landed).** `CommonEvents.json` was
      `[None]`, so a core feature had never executed — and it is two features,
      not one:

      * A **parallel** common event (trigger 2) is not a map event. It exists
        only while its switch is on (`Game_CommonEvent.isActive`), and when it
        does, it carries an interpreter of its own that `Game_Map.updateEvents`
        drives.
      * A **called** common event runs through `command117`, which builds a
        *child* interpreter inside the calling one (`_childInterpreter`,
        `_depth`) — the only nesting the interpreter ever does.

      The bed authors one of each, and `--mz_common_event_test`
      (`MZ_MODE=common`) drives both from a single command list run on the map
      interpreter: Control Switches turns on the switch the parallel event is
      gated on (nothing else can start it), and Call Common Event runs the
      other. They are reported separately, because driving one says nothing
      about the other. The state line also carries `commons=`/`active=` — how
      many `Game_CommonEvent` objects the map holds and how many have an
      interpreter — which distinguishes *the parallel event never became
      active* from *it ran and its write went nowhere*.

      Both worked: `parallel=11 called=22 commons=1 active=1`. Following M6.3l's
      lesson, the two variables they write were declared in `System.json` up
      front rather than discovered missing, and the parallel event is gated on
      switch 2 so it stays independent of the save probe, which sets switch 1.

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
