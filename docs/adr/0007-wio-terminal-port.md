# 7. Porting the RPG2k runtime to the Wio Terminal (SAMD51)

Date: 2026-07-24

## Status

Proposed

## Context

A core project goal (see ADR 1) is to run RPG Maker games "on any environment
such like embedded boards." The **Wio Terminal** (Seeed Studio) is an appealing
first real embedded target: it is a self-contained handheld with a screen,
buttons and an SD slot, built around the Microchip **ATSAMD51P19**:

- Cortex-M4F @ 120 MHz
- **512 KB internal flash**, **192 KB SRAM**
- 4 MB external QSPI flash (memory-mapped/XIP capable) — but **no external RAM**
- 320×240 ILI9341 LCD on SPI
- 3 top push-buttons + a 5-way navigation switch (up/down/left/right/press)
- microSD slot

The runtime is already structured so that a new display target is additive
rather than a rewrite — the same property that made the sixel (ADR 1), iTerm2
(ADR 3) and Emscripten backends cheap to add:

- **Rendering is LVGL, and LVGL is display-agnostic.** A display is a draw
  buffer plus a flush callback; the game never talks to SDL directly. The active
  display is injected once through the `rgss_set_display(M, d)` seam
  (`src/main.cxx`) and read back inside the gem via `get_display`
  (`mruby-rgss/src/lib.cxx`).
- **Input arrives through per-frame poll hooks.** `gfx_update`
  (`mruby-rgss/src/lib.cxx`) already calls `rgss_terminal_poll` and
  `rgss_sdl_poll` side by side; each backend buffers key transitions and drains
  them into `RGSS::Input` using integer key ids (`RgssKey` in
  `src/sdl_input.cxx`, mirrored in `mruby-rgss/mrblib/lib.rb`). Adding a backend
  means adding one more poll hook of the same shape (`input_bridge.cxx` is the
  reference).
- **Non-SDL timing is a solved problem.** The terminal backend
  (`mruby-rgss/src/terminal.cxx`, shared by sixel and iTerm2) already installs
  LVGL's tick/delay via `lv_tick_set_cb`/`lv_delay_set_cb` (a `CLOCK_MONOTONIC`
  clock and a `nanosleep`-based delay) instead of relying on SDL, which is
  exactly the shape a bare-metal board needs.
- **Handing the frame loop to a host that owns the event loop is a solved
  problem.** Under Emscripten, `src/main.cxx` does not run the blocking Ruby
  `loop do … end` (`mruby-rpg2k/mrblib/main.rb`); it registers a callback
  (`main_loop_`) that runs a single `main_loop` iteration per host tick. Arduino
  is the same shape: `loop()` calls one iteration.
- **Assets load through ordinary file I/O.** Game data is opened by path
  (`File.open "#{GAME_DIR}/RPG_RT.ldb"`, `mruby-rpg2k/mrblib/main.rb`) through
  mruby-io, and bitmaps through `std::fopen` (`mruby-rgss/src/lib.cxx`). On a
  board these resolve to newlib syscalls, which can be backed by the SD card.

What the Wio Terminal does *not* share with the existing targets is headroom.
The desktop and wasm builds treat memory as effectively unlimited
(`LV_MEM_SIZE` is 16 MB in `include/lv_conf.h`; the wasm heap grows on demand;
the Emscripten notes in `build_config.rb`/`src/main.cxx` mention game assets
loaded as strings exceeding 1 MiB). On the Wio Terminal **192 KB of SRAM is the
entire ceiling** for the mruby heap, the LVGL draw buffer, the C/C++ stack and
all statics combined, and there is no way to spill to RAM because the board has
none beyond that SRAM. This constraint — not the rendering or input wiring — is
the substance of the port, and it is why this ADR leads with a budget analysis
rather than a code sketch.

Everything below the "Decision" heading is a **design record and roadmap**. No
runtime or build code changes ship with this ADR; the intent is to agree the
architecture and confront the memory reality before any port code lands.

## Decision

Add the Wio Terminal as an additive backend behind the seams above, built with
the **PlatformIO / Arduino** toolchain (the de-facto standard for this board —
it supplies a working SAMD51 toolchain and upload flow, and off-the-shelf ILI9341
LCD, SD and GPIO drivers), while leaving the desktop CMake build untouched.

The pieces, each mirroring an existing pattern:

- **`mruby-rgss/src/wio.cxx` — display + input + timing backend.** Mirrors
  `sixel.cxx`/`iterm.cxx`. Exports `wio_display_create()` that calls
  `lv_display_create` in **`LV_DISPLAY_RENDER_MODE_PARTIAL`** with a *small* draw
  buffer, and a flush callback that pushes the dirty rectangle to the ILI9341
  over SPI (DMA where possible). It installs a `millis()`/`delay()` tick+delay
  source via `lv_tick_set_cb`/`lv_delay_set_cb` (as `terminal.cxx` does for the
  terminal backends) and exports `rgss_wio_poll(M)`, called from `gfx_update`
  next to the existing poll hooks, translating the 3 buttons + 5-way switch into
  `RgssKey` ids. Unlike the terminal backends the GPIOs give real key-release, so
  no `HOLD_MS` press-hold emulation is needed — press/release map straight onto
  `RGSS::Input.press`/`release`, as in the SDL path.
- **A PlatformIO project** (`platformio.ini`, board `seeed_wio_terminal`, an
  `app/wio_main.cpp` sketch) that compiles `libmruby.a` and the gems as a library
  and supplies `setup()`/`loop()`. `setup()` runs the `src/main.cxx` startup in
  Arduino form (`lv_init`, `wio_display_create`, `rgss_set_display`, set
  `GAME_DIR`/`RTP_DIR`, instantiate `RPG2k`); `loop()` runs one
  `game_obj.main_loop`, reusing the Emscripten frame-loop ownership pattern. The
  desktop-only dependencies of `src/main.cxx` (SDL, gflags, ng-log, inicpp/wine
  registry, `std::filesystem`, `std::regex`) are **not** compiled for this
  target — the Wio startup is a separate, slim entry point.
- **mruby ARM cross-build.** A `MRuby::CrossBuild('wio')` in `build_config.rb`
  using the `gcc-arm-none-eabi` toolchain, modeled on the existing
  `MRuby::CrossBuild('emscripten')`. As with emscripten, a native host build
  still produces `mrbc`, and presym handling must match between host and cross
  builds (see the existing emscripten notes in `build_config.rb`).
- **mruby heap in a fixed pool** via `mrb_open_allocf` (the desktop build already
  routes mruby through `lvallocf` in `src/main.cxx`; the Wio build routes it
  through a bounded pool) so the single biggest RAM consumer is capped and
  measurable rather than growing until it collides with the stack.
- **SD-backed filesystem.** newlib `_open`/`_read`/`_close`/`_lseek` syscall
  stubs over a FatFs SD driver, with `GAME_DIR` pointing at the game folder on
  the card (e.g. `/sd/<game>`) and `RTP_DIR` empty (self-contained games only;
  there is no wine registry on the board).

## Memory & flash budget

This is the section that decides whether the port is viable, and where the real
work is.

### SRAM (192 KB, hard ceiling — no external RAM)

| Consumer | Notes | Rough SRAM |
| --- | --- | --- |
| LVGL draw buffer (partial) | 320×20 RGB565, single-buffered | ~12.8 KB |
| LVGL draw buffer (partial, ×2) | double-buffered for DMA overlap | ~25.6 KB |
| LVGL internal + widget tree | scales with live sprites/objects | ~10–30 KB |
| C/C++ stack | mruby recurses deeply during init (see the wasm 8 MB stack note) | ~16–32 KB |
| BSS/statics (mruby VM, drivers, FatFs) | | ~20–40 KB |
| **mruby live heap** | **whatever is left** | **remainder** |

A **full framebuffer is explicitly rejected**: 320×240×2 = **150 KB** would by
itself consume ~78 % of SRAM. Partial/`LV_DISPLAY_RENDER_MODE_PARTIAL` rendering
of dirty rectangles is mandatory, and `LV_MEM_SIZE` in a Wio `lv_conf` must drop
from the desktop's 16 MB to a few tens of KB (or LVGL must be pointed at the same
bounded pool).

Netting the fixed costs out of 192 KB leaves only on the order of **a few tens of
KB for the mruby live heap**. That is the governing constraint: the amount of
*simultaneously live* game state (objects, and especially strings) must fit in
that window.

### The real blocker: whole-file asset loading

The engine currently reads whole asset files into mruby `String`s — the LCF
database (`RPG_RT.ldb`), map tree (`RPG_RT.lmt`) and each map (`Map####.lmu`) via
`File.open`/read (`mruby-rpg2k/mrblib/main.rb`), and image files via `std::fopen`
+ full-buffer decode (`mruby-rgss/src/lib.cxx`). The Emscripten path documents
these strings exceeding 1 MiB. **No single 1 MiB asset can exist in RAM on this
board**, let alone the database plus a map plus decoded bitmaps at once.

Therefore the port's largest engine change is **streaming / partial asset
loading**: read LCF structures and image data from SD incrementally, decode only
what is needed into small LVGL-managed bitmaps, and free promptly — instead of
materializing whole files as strings. This is deferred to a dedicated phase
below because it touches the LCF reader and the bitmap loaders, not just the
backend.

### Flash (512 KB internal + 4 MB external QSPI)

The concern here is code + read-only data size, dominated by:

- **onigmo** (via `mruby-onig-regexp`) — a full regex engine, easily hundreds of
  KB.
- **uni-algo** Unicode tables.
- mruby core + all gems (`mruby-lcf`, `mruby-rgss`, `mruby-rpg2k`,
  `mruby-rpgxp`, marshal, stringio) and the compiled Ruby bytecode.

This plausibly overruns the 512 KB internal flash. Levers, to be **measured in
Phase 1** rather than assumed:

- Drop `mruby-onig-regexp` if the target games' scripts don't require regex, or
  swap in a much smaller matcher.
- Slim `uni-algo` (only the normalization/case tables actually used).
- Place read-only bytecode, rodata and — importantly — the game assets in the
  **4 MB external QSPI flash** (XIP / a read-only FS), keeping internal flash for
  hot code.

### LCD bandwidth (frame rate)

Like ADR 1's sixel bandwidth analysis, the output side is throughput-bound, but
here by the SPI link to the ILI9341 rather than a terminal. A full 320×240 RGB565
frame is ~150 KB (~1.2 Mbit); at a ~48 MHz SPI clock that is a ~32 ms transfer,
i.e. well under 60 Hz for a *full* redraw. This is fine because LVGL only flushes
**dirty rectangles**: menus, message windows and cursor movement touch small
regions and stay comfortable, while **full-screen map scrolling** (the whole
screen changes every step) is the worst case and will set the practical frame
rate. DMA-driven flush with a double buffer, and possibly a coarser scroll step,
are the tuning levers.

## Consequences

- **Advances the "run anywhere" goal** onto genuine embedded hardware, and does
  so behind the same seams the sixel/iTerm2/Emscripten backends already use, so
  the desktop, wasm and terminal builds are **unchanged** — the Wio backend is
  purely additive (a new gem source file, a separate PlatformIO entry point, and
  a new cross-build stanza).
- **The port is gated by RAM, not by wiring.** Standing up the display, input,
  timing and SD filesystem is well-trodden; the hard, novel work is fitting the
  live working set into a few tens of KB, which forces the streaming asset rework
  and disciplined heap sizing. This ADR states that cost honestly up front rather
  than discovering it after a half-built backend.
- **Not yet a working firmware.** This is a design record. It cannot be verified
  without the hardware and a full ARM cross-build; the numbers above are budget
  estimates to be replaced with real `size`/heap measurements in Phase 1. It is
  entirely possible Phase 1/2 conclude that a particular game does not fit and
  that either the game assets or the gem set must be trimmed further.
- **Risk register:** the 192 KB hard ceiling (no spill); the invasiveness of the
  asset-streaming change to the LCF reader and bitmap loaders; internal-flash
  overflow forcing gem trimming or QSPI XIP; and map-scroll frame rate over SPI.

### Roadmap

- **P0 — this ADR.** Design and budget; agree the approach.
- **P1 — HAL bring-up.** `wio.cxx` backend, PlatformIO project, newlib/SD
  syscalls, and the mruby ARM cross-build. Exit criteria: mruby boots, a test
  LVGL screen draws on the LCD, a file reads from SD, and buttons reach
  `RGSS::Input` — with **real flash/RAM `size` numbers captured** to replace the
  estimates above.
- **P2 — fit flash.** Trim gems (regex/uni-algo), and move rodata/bytecode/assets
  to QSPI as needed, until the image links within budget.
- **P3 — asset streaming.** Rework LCF and bitmap loading so game data is read
  from SD on demand instead of whole-file strings; target the title screen
  rendering from a real game folder.
- **P4 — gameplay.** Map scene, event interpreter input, and save/continue; tune
  the flush path to the achievable frame rate.
