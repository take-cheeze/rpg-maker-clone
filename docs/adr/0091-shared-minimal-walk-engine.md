# 91. One minimal walk engine, shared by the iPod nano 7G and the Wio Terminal

Date: 2026-09-07

## Status

Accepted

## Context

ADR 61 built a from-scratch, non-mruby map-walking engine in C for the iPod
nano 7th generation, because NanoApps caps a homebrew app's uploaded image at
roughly 500 KB and this repo's mruby + RGSS/RPG2k gem stack is tens of MB. It
was written as one file against NanoApps' `RAW_SURFACE` API
(`app/nano7/rpg2k_walk/rpg2k_walk.c`), with the file format, the movement
rule, the camera and the tile compositing interleaved with `hb_fs_read`,
`hb_raw_blit` and the touch joystick.

The **Wio Terminal** port (ADR 7) has been parked at P1 — an LVGL HAL
bring-up firmware with no interpreter — since it was written, and its own
budget section says why. 192 KB of SRAM is the ceiling for the mruby heap,
the LVGL draw buffer, the stack and every static combined, with no external
RAM to spill to; 512 KB of internal flash probably does not hold onigmo plus
uni-algo plus the gems; and the engine reads whole assets into mruby
`String`s, which the Emscripten notes already document exceeding 1 MiB. The
roadmap's answer is P2 gem trimming and a P3 streaming-asset rework of the
LCF reader and the bitmap loaders — a large, invasive change to shared engine
code that nobody has started.

Meanwhile the nano 7G engine is 4.7 KB of ARM code with a 209 KB working set,
and the device half of it — read two files, blit tiles, read a direction —
is roughly forty lines. A Wio Terminal has a 320x240 LCD, a 5-way switch and
an SD card. It can obviously run *that*, today, with no interpreter, no
streaming rework and no gem trimming, because the interpreter's work already
happened on the host.

Nothing in the engine was device-specific except the I/O. What kept it from
being shared was only that it had never been separated from it.

## Decision

Split the nano 7G app into a platform-independent core plus a platform half,
and add a second platform half for the Wio Terminal:

- **`app/shared/rpg2k_walk/rpg2k_walk_core.{c,h}`** — the engine. Freestanding
  C: no libc, no allocation, no I/O, no globals. It parses the exported
  `map.bin` header, resolves per-cell tile indices and the passability mask,
  applies RPG2000's own movement rule (both halves of
  `Scene::Map#char_passable?`, baked into the export), clamps the camera, and
  composites a cell's two layers into one opaque ARGB1555 tile.
- **The platform owns the buffers.** `rw_open` takes the bytes the platform
  read and how many, so a device states its caps by declaring the arrays it
  can afford: an export that does not fit arrives short and is refused
  (`rw_status`), never read past. That is what lets one device give the atlas
  128 KB and another 80 KB with no `#ifdef` anywhere in the core.
- **`app/nano7/rpg2k_walk/rpg2k_walk.c`** keeps only the NanoApps half:
  `hb_fs_read` into `.bss`, the whole-screen touch joystick, the step timer,
  ARGB1555 -> the raw surface's 32-bit pixels, `hb_raw_blit`.
- **`app/wio/src/walk_main.cxx`** is the new Arduino half, built by a new
  `wio_walk` PlatformIO environment: the microSD card through
  `Seeed_Arduino_FS`, the LCD through `Seeed_Arduino_LCD`
  (ARGB1555 -> RGB565 -> `pushImage`), and the board's 5-way switch read
  directly. It links **neither LVGL nor mruby** — it is not the `wio`
  environment with pieces switched off, it is the other engine.
- **The exporter gains `--target nano7|wio`** (`scripts/export_nano7_map.rb`),
  whose per-target caps mirror each firmware's declared buffers, so a map too
  big for a device is refused on the host with a clear message rather than
  failing to load on it. nano7 stays 128x128 / 256 atlas entries (~209 KB);
  wio is 64x64 / 160 entries (~100 KB of its 192 KB SRAM, chosen so real maps
  — Nepheshel's world map composites to 137 entries — actually fit).
- **`scripts/stage_nano7_walk_app.bash`** copies the app and the core into a
  NanoApps checkout together, since NanoApps builds from inside its own tree
  and `sdk/hb_app.mk` resolves `SRCS` relative to the app directory.
- **The core gets a CI test** (`app/shared/rpg2k_walk/test/walk_core_test.c`,
  the `walk_core` ctest). Neither device is reachable from CI — no toolchain,
  no emulator, no board — but the core is plain C with no I/O, so format
  parsing, the movement rule, camera clamping and layer compositing run on
  the host against synthetic fixtures built byte by byte in the exporter's
  format. ADR 61 had to say the port's only automated coverage was the
  exporter check; the half that runs on the device now has some too.

### What was measured

The nano 7G app was rebuilt against a real NanoApps checkout with
`arm-none-eabi-gcc` 13.2, before and after this ADR's changes and ADR 61's
transparency fix, so the numbers are the same toolchain on both sides:

| | `.text` | `.bss` | packed `.hbapp` |
| --- | --- | --- | --- |
| ADR 61's first slice | 4,291 B | 344,156 B | 4,551 B |
| ARGB1555 tiles + shared core | 4,712 B | 214,628 B | 4,940 B |

421 bytes of code (the layer compositing and the pixel conversion) buys
127 KB of working set, and the packed image stays under 1% of NanoApps'
500 KB ceiling.

The Wio firmware is **not** build-verified: PlatformIO's package registry is
not reachable from the environment this was written in, so `pio run -e
wio_walk` could not resolve the `atmelsam` platform. What was checked is that
the sketch compiles as C++ against stub declarations matching the real
`TFT_eSPI` / `Seeed_FS` signatures (read out of those libraries' own
headers), and that the core it calls passes its host test. Treat the
environment as untested on hardware until someone with a board runs it — the
same standing as ADR 7's own P1 firmware, and stated in `app/wio/README.md`.

## Consequences

- **The Wio Terminal runs real RPG Maker map data now**, without waiting for
  P2/P3. What it runs is deliberately not the engine: no events, no battle,
  no menus, no interpreter. The mruby route in ADR 7 is not cancelled or
  replaced by this — the `wio` environment and its roadmap stand — but it is
  no longer the only thing that could ever run on the board.
- **A second consumer keeps the format honest.** The exporter's output is now
  read by two independent platform halves with different pixel formats and
  very different budgets, which is what turned "the on-device caps" from
  constants compiled into one app into an explicit part of the core's API.
- **A change to the walk engine now touches two firmwares.** Neither can be
  built in CI, so the host test is the guard rail: anything that could be
  wrong in the core belongs there rather than in a device-only code path.
  Anything genuinely device-specific stays in the platform half, where it is
  visibly device-specific.
- **The nano's app directory is no longer self-contained**, hence the staging
  script. Copying only `app/nano7/rpg2k_walk` into NanoApps now fails to
  build with a missing `rpg2k_walk_core.c` — a loud failure, not a silent
  one, and the README leads with the script.
- Both READMEs still frame these as "walk a map," not "play the game." That
  has not changed and is not meant to.
