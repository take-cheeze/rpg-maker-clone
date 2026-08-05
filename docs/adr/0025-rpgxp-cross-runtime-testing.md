# 25. Testing RPG Maker XP against the browser build and the genuine RGSS runtime

Date: 2026-08-04

## Status

Accepted — the native check runs green on the OpenGame.exe XP test bed; the wine
comparison is a manual/dev script, like its RPG2000 counterpart.

**Amended 2026-08-05: the browser check was dropped.** Driving a real browser
needed a `chromium` in the dev shell, and that one package dominated the
download of every `nix develop` — on every machine and every CI job, for a
single non-blocking smoke test. `scripts/rpgxp_browser_check.py` and its `wasm`
CI steps are gone; the two page-only bugs it found are fixed and stay fixed, and
the native and wine legs of this ADR are unchanged. The browser build is again
covered only by "it compiles"; re-testing it needs a browser dependency that
pays for itself (see Consequences).

## Context

The RPG Maker XP runtime (`mruby-rpgxp`) had two kinds of coverage:

- **Data-layer checks under CRuby** — `scripts/rpgxp_testbed_check.rb` and
  `scripts/rpgxp_script_host_check.rb` load the very same `mrblib/*.rb` sources
  under CRuby and drive them over a real project's `Data/*.rxdata`.
- **Unit tests** — `mruby-rpgxp/test`, run by the per-gem `rake test`.

Neither one runs the *engine*. The RPG2000 side learned twice over that this is
not enough (ADR 0021): a bare `module_function` and `Enumerable#none?` both pass
under CRuby and both break the real mruby build, so `rpg2k_boot_check.bash` boots
the actual binary, and `compare-nepheshel-wine.bash` diffs its frames against the
genuine `RPG_RT.exe` under wine. The XP side had neither.

Two XP-specific gaps made that worse:

1. **The browser is a third runtime, and nothing tested it.** The page
   (`src/shell.html` + the emscripten build) has failure modes the native binary
   cannot have: its loader mounts a project into the virtual filesystem at
   *runtime*, `rpg_start_game()` picks the runtime from what landed there,
   keyboard input arrives as DOM events, and the frame loop is the browser's, not
   ours. The build being green says nothing about any of it. The XP path is also
   the *newest* consumer of that loader (`Game.ini` detection was added to it),
   and the page is what GitHub Pages and the `/preview` deployments serve.
2. **There is a genuine XP runtime we can run.** The `OpenGame.exe` test bed the
   repo already downloads ships Enterbrain's `Game.exe` + `RGSS104E.dll` beside
   its `Data/*.rxdata` — both PE32, both runnable under wine. So the XP renderer
   can be held against its reference the same way the RPG2000 renderer is,
   instead of being judged by eye.

## Decision

Test an XP project in **all three** runtimes it can run in, with one shared
marker so the three checks assert the same thing.

- **A machine-readable "reached the map" marker and a way to get there without
  input.** `--rpgxp_new_game` selects New Game once on the title screen, and
  `RPGXP#start_new_game` logs `[RPGXP-MAP] map=<id> x=<x> y=<y>` — deliberately
  mirroring `--rpg2k_new_game` / `[RPG2k-MAP]`, down to reading the flag's
  constant through its own `rescue` (`Module#const_get` is not in this mruby
  build's gem set).
- **Native: `scripts/rpgxp_boot_check.bash`.** Boots the built binary on the XP
  test bed under Xvfb and fails unless `[RPGXP-MAP]` shows up. This is the guard
  against mruby/CRuby divergence in the XP runtime, and it runs in CI as a
  blocking check.
- **Browser: `scripts/rpgxp_browser_check.py`** (removed — see Status). Served
  the built page, handed it
  a zip of the XP project through the shell's own loader, pressed the decision
  key, and asserted: the runtime initialises, the project mounts, the game starts
  and the loader panel goes away, the display is XP-sized, `[RPGXP-MAP]` appears,
  arrow keys change the frame, the canvas is not blank, and nothing in the page
  log looks like an mruby exception. Screenshots of every step were written out.
  It ran in the `wasm` CI job, uploading those frames — non-blocking, the way the
  MV/MZ smokes were staged, since it was the repo's first check to drive a real
  browser and a flake there would block the page deployment.
- **Reference: `scripts/compare-rpgxp-wine.bash`.** Boots the project's own
  `Game.exe`/`RGSS104E.dll` under wine and our engine on two Xvfb displays at
  640x480, feeds both the same key script, and writes per-step ref/ours/diff/cmp
  frames plus a differing-pixel count — the XP counterpart of
  `compare-nepheshel-wine.bash`. One detail makes this share more than its shape
  with the RPG2000 script: an editor-made XP project keeps its graphics in the
  **RTP**, and our engine resolves the RTP through the *wine prefix's* registry
  (`xp_rtp_path()` reads `Software\Enterbrain\RGSS\RTP\Standard`), so
  `scripts/rtp_xp_install.bash` into that prefix feeds the reference and the
  clone the same assets.

### Driving a browser without adding a dependency

The repo has no `package.json` and no npm/pip dependencies — deliberately;
`src/shell.html` even unpacks zips with `DecompressionStream` rather than bundle
a zip library. A Playwright/Puppeteer dependency for one smoke test would be the
largest new dependency in the tree.

So `rpgxp_browser_check.py` talked to headless Chromium over the **DevTools
protocol using the Python standard library alone**: a ~90-line RFC 6455
WebSocket client, `Runtime.evaluate` / `Input.dispatchKeyEvent` /
`Page.captureScreenshot`, and a small non-interlaced PNG reader (zlib plus the
five filter types) for the blank-frame assertion. The only new dependency was the
`chromium` binary, added to the dev shell in `flake.nix`.

That accounting turned out to be the mistake this was amended for. "One binary"
is cheap to *write* against and expensive to *fetch*: chromium is by far the
largest closure in the dev shell, and every `nix develop` — every contributor's
first build, every CI job in every workflow, whether or not it touches the
browser at all — paid for it. A dependency that only one non-blocking check uses
does not earn a place in the shell every other check has to realise.

## Consequences

**Found immediately, in the browser, on the first run** — two bugs that only the
browser build has, both now fixed here:

- **An XP project loaded in the page rendered on a 320x240 screen.** Native
  `main()` sizes the display to 640x480 from `--game_dir` *before* creating it,
  but in the browser no project exists at that point — the page's loader mounts
  one later — so the display stayed at the 320x240 default (doubled to a 640x480
  window, which is why the canvas *looked* right). The XP scenes then drew off
  the edge: the title's command window landed past the bottom and its centred
  text past the right. `rpg_start_game()` now resizes the display when it
  detects an XP project, and logs `[RPGXP] display sized to 640x480`, which the
  check asserted on — the canvas size alone cannot tell the two cases apart.
- **The loader panel stayed on screen above the running game.** It is dismissed
  by setting `hidden`, which the page's own `.panel { display: flex }` rule
  overrode. The fix sets the computed style, not just the property.

Both fixes are in the engine and the page and stay there; what the amendment
gives up is the *regression* guard, not the fixes.

**Found by the wine comparison, on its first real run** — four bugs that kept an
XP project from drawing what the genuine runtime draws, all fixed here:

- **The XP RTP was never looked up.** `xp_rtp_path()` (the
  `Software\Enterbrain\RGSS\RTP\Standard` key) existed but nothing called it:
  `RTP_DIR` was always the RPG2000 `Software\ASCII\RPG2000` path, so an XP
  project could not find a single RTP asset and every graphic fell back to a
  placeholder. The RTP is now picked by project type.
- **`.jpg` was not in the asset search.** The XP RTP genuinely mixes formats —
  windowskins and charsets are PNG, title backgrounds are JPEG — and the Bitmap
  loader only tried `.png`/`.xyz`/`.bmp`, so every XP title screen stayed on the
  fallback background. stb already decodes JPEG.
- **Truecolour images were drawn with red and blue exchanged.** Every loader in
  `mruby-rgss` hands back LVGL's B, G, R(, A) order, but stb decodes to
  R, G, B(, A); the vendored stb carries a BGR hack that covers *indexed* PNGs
  only — which is all an RPG2000 project has. XP's truecolour PNGs and JPEGs
  came out channel-swapped. stb's output is now swapped explicitly, and the
  RPG2000 title screen renders byte-identically before and after.
- **An RGBA image loaded opaque drew garbage.** The bitmap's pixel format was
  chosen from the *file's* channel count while the data was decoded with the
  *requested* one, so an RGBA source loaded without the transparent flag filled
  a 4-byte-per-pixel bitmap from 3-channel data — reading past the buffer. XP's
  truecolour windowskin hit exactly that. The format now follows the request.

- **The title's command window was the wrong size.** RMXP's `Scene_Title` builds
  `Window_Command.new(192, ...)`; ours was 240 wide, so it sat 48 too wide and 24
  too far left. Its height and y were already right.

Measured on the title screen, that took the frame from **227,389 differing
pixels (74%)** to **47,377 (15%)**, and the window frames now land on the
reference's pixels. What is left inside the window is the reference drawing *no*
text at all — RGSS finds no font in the wine prefix — our solid selection bar
against its translucent one, and a level or two per channel from a different
JPEG decoder.

**Follow-ups this opens:**

- The XP tile layers still render as placeholder colour blocks, so the wine
  comparison's map steps will differ wholesale until real tileset/autotile
  blitting lands; the comparison exists to drive exactly that work, as it did for
  RPG2000 (ADR 0021 / 0016).
- **The browser build is untested again.** Nothing now exercises the page's
  loader, its DOM input path or its frame loop; a green wasm compile is all the
  coverage there is, exactly as before this ADR. Getting it back means a browser
  that does not sit in the dev shell — a system chromium the check finds only if
  present and skips when it is not, or a browser-only CI job whose fetch does not
  land on every other job. The three things the removed check would want, if it
  returns: the **script host** (`RGSS_SCRIPT_HOST`, ADR 0017/0023) run in the
  page (the ADR 0023 frame driver was written for the browser and has never been
  verified there), a **packed release** (`Game.ini` + `Game.rgssad`, no loose
  `Data/`) loaded through the shell — the shape most XP games ship in, and a
  different path through both the loader and `RGSSData` — and a way to **pass
  engine flags to the page**, since reaching the map by pressed keys is the more
  faithful test but makes a title-screen regression and an input regression fail
  the same assertion.
