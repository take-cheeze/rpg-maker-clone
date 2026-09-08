# 102. A host-side emulator for the iPod nano 7G walk app

Date: 2026-09-08

## Status

Accepted

## Context

ADR 61 built `app/nano7/rpg2k_walk`, a from-scratch NanoApps homebrew app
that walks a real RPG Maker 2000/2003 map on a jailbroken iPod nano 7th
generation. ADR 91 split it into a shared, platform-independent core
(`app/shared/rpg2k_walk`, plain C with no I/O, covered by the `walk_core`
ctest) and a thin NanoApps platform half (`app/nano7/rpg2k_walk/rpg2k_walk.c`)
that reads two files, drives a touch joystick and blits tiles through
`hb_raw_surface`'s six-function API. Both ADRs say the same thing about that
platform half: "neither device is reachable from CI — no toolchain, no
emulator, no board" (ADR 91) — it is verified once, by hand, on real
hardware, and never again after that.

ADR 94 closed the equivalent gap for the Wio Terminal port with a
[Renode](https://renode.io) platform: a C# peripheral model of the board's
Cortex-M4F, clock tree, SPI controller and ILI9341 display, driving the
*actual compiled firmware ELF* far enough to prove real SPI traffic renders
real pixels, without hardware. The obvious first idea here was the same
approach — model the iPod nano 7G's SoC and boot it under Renode or QEMU.

That idea does not fit this port, for reasons specific to what each device's
firmware actually is:

- **The Wio Terminal firmware is bare-metal.** Arduino's `startup.c` runs
  first, on real silicon, and the firmware itself pokes SAMD51 clock/SPI/GPIO
  registers directly — modelling the SoC's MMIO *is* modelling the firmware's
  entire execution environment. A CPU-accurate peripheral model is both
  necessary and sufficient.
- **The iPod nano 7G app is not bare-metal.** `hb_sdk.h`'s own file header
  says it plainly: apps are flat-binary blobs the *existing, signed Apple
  retailOS* loads and execs via a jailbreak (`ipod_sun`/Pixosn0w), on a
  Cortex-A8 SoC (`sdk/hb_app.mk`: `-mcpu=cortex-a8`) running a full
  proprietary OS and UI framework ("Silver") this project has no source for
  and no legal way to obtain. `rpg2k_walk.c` never touches a register at
  all — every hardware interaction goes through `hb_raw_surface.h`'s six
  functions (`hb_raw_fb/w/h/fill/fill_rect/rect_outline/disc/blit`) plus
  `hb_fs_read`, `hb_time_uptime_ms` and `hb_draw_str` from `hb_sdk.h`, all
  implemented by SDK/OS code this repo does not ship and did not write.
  Booting this under Renode/QEMU would mean either (a) modelling a Cortex-A8
  application processor plus enough of an undocumented, unpublished Apple SoC
  and its OS to reach the point homebrew code runs at all — an
  reverse-engineering project with no public prior art (confirmed: no
  SAMD51-scale peripheral table like ADR 94's exists for this chip in
  upstream Renode, nor does freemyipod's own tooling include a CPU emulator),
  orders of magnitude past ADR 94's SPI/clock-tree stub set — or (b) actually
  running Apple's real, signed OS binary under emulation, which this project
  has neither the legal standing nor the reverse-engineered SoC model to do.
  Neither is "unverified until attempted" the way ADR 94's DMAC gap was; both
  are known, from what is already public about this platform, to be a
  different order of project.
- **The API this app runs against is already the right abstraction
  boundary.** `hb_raw_surface.h` is a six-function, OS-hosted framebuffer
  API — closer in shape to a game console's libc than to bare-metal MMIO.
  Nothing about `rpg2k_walk.c`'s own logic (tile compositing, the touch
  joystick, the movement rule via the shared core) depends on being *on* a
  Cortex-A8 or *under* Apple's OS; it depends only on that six-function
  contract being honoured. Emulating hardware to get back to an API the app
  never leaves is solving a harder problem than the one that is actually
  blocking CI coverage.

## Decision

Build a **host-side implementation of the exact `hb_raw_surface`/`hb_sdk`
subset `rpg2k_walk.c` calls**, and link the app's own unmodified device
source against it as a native executable — the same "faithful to the real
interface, not a guess" discipline ADR 94's `ILI9341_SPI` and
`SAMD51_SERCOM_SPI` peripherals used, aimed at the API boundary instead of
the register boundary because that is where this device's real boundary is.

- **`app/nano7/host/include/{hb_surface_input,hb_raw_surface,hb_sdk}.h`** —
  drop-in headers matching upstream NanoApps
  (`nfzerox/NanoApps@80d439d`) declaration-for-declaration (reformatted to
  this repo's own clang-format style, not kept byte-identical) for the two
  small, stable headers this app includes in full (`hb_surface_input.h`,
  `hb_raw_surface.h`), and a **verified subset** of `hb_sdk.h` covering only
  what `rpg2k_walk.c` and `rpg2k_walk_core.c` actually call
  (`HB_RGB`/`HB_BLACK`/`HB_WHITE`, `hb_draw_str`, `hb_fs_read`,
  `hb_time_uptime_ms`, `HB_SCREEN_W`/`HB_SCREEN_H`) — signatures checked
  against the real file, not guessed, the same way ADR 94 read `SD.SDCard`'s
  actual `Transmit()` before relying on it.
- **`app/nano7/host/nano7_host_shim.c`** implements that contract on top of
  SDL2 (already this repo's own dependency — `SDL2::SDL2`, no new one
  added): a static `HB_SCREEN_W x HB_SCREEN_H` `XRGB8888` array *is*
  `hb_raw_fb()` (the real header already documents that exact layout, so no
  conversion step exists to get wrong), `hb_fs_read` joins its path argument
  onto a configurable host data root (so an export's `map.bin`/`tiles.bin`
  drop into `<root>/Apps/Data/RPG2kWalk/`, the same relative shape the real
  device's own data directory uses), and `hb_time_uptime_ms` is a clock the
  harness controls — real wall-clock time in interactive mode, a
  caller-advanced counter in headless mode, so a batch run's `STEP_INTERVAL_MS`
  timing is exact rather than raced against however fast the host CPU
  happens to loop. `hb_draw_str` is a deliberately non-faithful placeholder
  (a blocky per-character rectangle, not upstream's real glyph bitmap font,
  `sdk/generated/hb_glyphs.c`) — it only ever draws this app's "no map to
  walk" error screen, never the map-rendering path this harness exists to
  check, so pixel-exactness there is not worth the bitmap font's own size.
- **The executable links `rpg2k_walk.c` and `rpg2k_walk_core.c` verbatim.**
  No device source file is forked or `#ifdef`'d for the host build; the only
  new code is the shim underneath the same three functions the real SDK
  underneath it. A regression in tile compositing, the movement rule, camera
  clamping, or the touch-joystick direction math — the exact class of bug
  ADR 91 already flagged as reachable from CI via `walk_core_test` — is now
  also reachable *through the real device entry points*
  (`hb_raw_init`/`hb_raw_frame`), which `walk_core_test` alone cannot
  exercise since it never links `rpg2k_walk.c`.
- **CI needs no display.** Because `hb_raw_fb()` is a plain in-process array,
  a headless run (`--frames N --screenshot out.bmp`) never calls
  `SDL_Init`/`SDL_CreateWindow` at all — `SDL_CreateRGBSurfaceWithFormatFrom`
  and `SDL_SaveBMP` work on a bare array with no video subsystem. Unlike this
  project's other SDL-window ctests (`exe_open`, `render_probe`, …), this one
  needs no `xvfb-run` and no reserved `--server-num`. Interactive use (a real
  window, mouse-as-touch) is still available by omitting `--frames`, for
  actually looking at a map the way ADR 94's Renode work let you look at a
  simulated LCD.
- **`scripts/nano7_host_smoke.bash`** exports Nepheshel map 1 with
  `scripts/export_nano7_map.rb --target nano7` into a scratch
  `Apps/Data/RPG2kWalk` tree, runs `nano7_walk_host` headless for 60 simulated
  frames — long enough (`STEP_INTERVAL_MS` = 160 ms, the simulated clock
  advances 20 ms/frame) to hold a synthetic "move down" touch through several
  real steps, not just the first static frame — and saves a BMP.
  **`scripts/nano7_host_smoke_check.rb`** (plain Ruby, a BMP reader in the
  style `scripts/mz_frame_check.rb` already uses for PNG, no ImageMagick
  dependency) asserts the frame is not a flat fill and carries a minimum
  number of distinct colours, the same "did real content actually land"
  signal `mz_frame_check.rb`'s own comment explains was the check that would
  have caught that project's own silent-blank-frame regression. Wired into
  `CMakeLists.txt` as ctest `nano7_host_smoke`, alongside `walk_core`.

## Consequences

- **CI now exercises the real device entry points**, not just the core
  behind them — a defect only reachable through `rpg2k_walk.c` itself
  (buffer sizing against the real `MAP_BIN_MAX_BYTES`/`MAX_TILES` macros, the
  touch-joystick deadzone/axis-priority logic, the `hb_fs_read` two-file
  load path, the ARGB1555→XRGB8888 conversion) is now caught the same way a
  `walk_core_test` regression already was, closing the gap ADR 91 named and
  left open.
- **Does not replace real-hardware verification**, for the same reason ADR
  94 says Renode does not replace a real Wio Terminal: this harness is only
  as faithful as the shim underneath it, and nothing here proves the real
  NanoApps `hb_raw_surface` runtime behaves identically — only that this
  app's own logic, run through *a* correct implementation of the documented
  contract, produces a real map render. A quirk in the real OS compositor or
  touch digitizer (the equivalent of ADR 94's `to565`/`to565_push` dual-
  encoding surprise) would not be caught here, and README's existing "verified
  on real hardware" claim continues to rest on the hardware session ADR 61
  documents, not on this harness.
- **No new build dependency.** SDL2 is already vendored/linked for the
  desktop, Emscripten and Android builds; this reuses the same
  `SDL2::SDL2` target `src/main.cxx` already links, unlike ADR 94's Renode
  work which needed a from-source build of a whole separate project.
- **Narrower scope than ADR 94 on purpose.** This harness cannot catch a bug
  in the real OS/SDK layer (there is none to be wrong here — it does not
  exist in this repo), only in this repo's own app code. That is the correct
  scope for what is actually unverified by `walk_core_test`: the shared core
  was already covered; the platform glue around it was not.
