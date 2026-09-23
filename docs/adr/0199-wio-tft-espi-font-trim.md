# 199. Drop the TFT_eSPI bitmap fonts 2/4/6/7/8 nothing on the Wio Terminal draws

Date: 2026-09-22

## Status

Accepted

## Context

A fresh `scripts/wio_bc2cpp_measure.bash` run at 5d879a5 put
`libSeeed_Arduino_LCD.a(TFT_eSPI.cpp.o)` at 20,934 bytes of the
`wio_rgss_boot` image. docs/adr/0141 had flagged exactly this object for a
"per-function audit for board-specific dead paths" and left it, because
`Seeed_Arduino_LCD` (Seeed's TFT_eSPI fork) is a vendor library shipped
inside the `framework-arduino-samd-seeed` PlatformIO package, not something
this repo vendors or patches.

Splitting that object by input section (from the real `firmware.map`) showed
what it is: 13,462 bytes of glyph tables for fonts 2, 4, 6, 7 and 8
(`chr_f16_*`/`chrtbl_f16` ... `chrtbl_f72`: font 2 2,064, font 4 5,058,
font 6 1,970, font 7 1,770, font 8 2,600), 1,275 for font 1 (GLCD), and about
6,000 of actual driver code. The library's bundled `User_Setup.h` `#define`s
every font unconditionally, and `--gc-sections` cannot drop them because
`drawChar`/`drawString` are virtual -- the vtable keeps them, and they keep
the tables.

None of it is drawn:

- `env:wio` and `env:wio_rgss_boot` reach TFT_eSPI only through
  `mruby-rgss/src/wio.cxx`, which calls `begin`, `setRotation`,
  `setSwapBytes`, `fillScreen`, `startWrite`, `setAddrWindow`, `pushColors`
  and `endWrite`. That is all it does. Their on-screen text is LVGL's own
  Montserrat font, and real game text goes through mruby-rgss's
  shinonome/cp932 pipeline.
- `env:wio_walk` does call `drawString()`. But `setTextFont`, `setFreeFont`
  and `loadFont` appear nowhere in the repo, so it only ever renders the
  default font 1 (GLCD).

## Decision

**First attempt, rejected: configure TFT_eSPI through `build_flags`.**
`app/m5stack/platformio.ini` configures Bodmer's mainline TFT_eSPI this way:
`-DUSER_SETUP_LOADED=1` plus the pins and `-DLOAD_GLCD=1`. It does not carry
over to this fork, for three reasons:

1. **`USER_SETUP_LOADED` does not keep `User_Setup.h` out.** It only skips
   the include in `TFT_eSPI.h`. `TFT_Interface.h` still does an
   unconditional `#include <User_Setup.h>`, and `TFT_eSPI.cpp` includes that
   after the class is declared. The fonts' `#ifdef LOAD_FONT2` code then
   compiles with the tables never included (`'widtbl_f16' was not declared
   in this scope`). The same late include caused the confusing
   `no declaration matches TFT_eSPI::setBacklight` and `'gfxFont' was not
   declared` errors of the earlier tries: `TFT_BL` and `LOAD_GFXFF` got
   defined after the class body was already declared without them.
2. **The obvious pins were the wrong ones.** The board definition passes
   `-DSEEED_GROVE_UI_WIRELESS`. So the branch of `User_Setup.h` that really
   applies is the one using `LCD_SPI`, `LCD_SS_PIN`, `LCD_DC`, `LCD_RESET` and
   `LCD_BACKLIGHT`, not the plain `ARDUINO_ARCH_SAMD` branch below it with
   literal pins 5/6. Copying the plain branch compiled far enough to show
   that a copied pin block can go wrong without any error, and in a way only
   real hardware would catch.
3. **Class layout.** libmruby.a's `wio.o`, which defines the
   `TFT_eSPI g_tft` global, is compiled by the mruby cross build and never
   sees PlatformIO `build_flags`. Any macro that changes the `TFT_eSPI`
   class body (for example `LOAD_GFXFF`, which gates its `gfxFont` member)
   would give the two sides different layouts. That links fine and corrupts
   memory.

**What landed: `app/wio/patch_tft_espi_fonts.py`, a no-op-by-default patch
to the installed package.** It follows the pre-script pattern
`app/maix/patch_wire_i2c_timeout.py` set for framework-maixduino. The script
only wraps the five `#define LOAD_FONT2/4/6/7/8` lines of the installed
`User_Setup.h` in `#ifndef RPGMAKER_WIO_TFT_NO_EXTRA_FONTS`. It is idempotent
(it checks for the guard) and asserts that the five lines are still
consecutive, so a library update fails loudly instead of silently doing
nothing. A build without that macro compiles exactly what it did before, so a
package patched by one environment or checkout never changes what another
compiles. `env:wio`, `env:wio_walk` and `env:wio_rgss_boot` list the script
and define the macro. `env:wio_sim` and the two `wio_rgss_boot_heapdbg*`
environments inherit it through `extends`.

`LOAD_GLCD` and `LOAD_GFXFF` stay outside the guard. `env:wio_walk` needs
GLCD. The class body depends on GFXFF (point 3 above). With neither defined,
the library does not build at all, because its `#ifdef` nesting around
`drawChar` needs one of them (reproduced).

## What was verified

- **Only font macros change.** Running `arm-none-eabi-g++ -E -dM` on
  `TFT_eSPI.cpp` with env:wio's real compile command, with and without the
  flag, gives this diff: `LOAD_FONT2/4/6/7/8`, the derived `LOAD_RLE`, the
  fonts' own size macros (`chr_hgt_f16` ...), and the new
  `RPGMAKER_WIO_TFT_NO_EXTRA_FONTS`. The pins, SPI settings, `TFT_BL`,
  `LOAD_GLCD`, `LOAD_GFXFF` and `SUPPORT_TRANSACTIONS` are all unchanged. The
  class body in `TFT_eSPI.h` depends only on `LOAD_GFXFF`, `SMOOTH_FONT` and
  `TFT_BL`, and `Extensions/*.h` depend on no `LOAD_*` macro. So libmruby's
  `wio.o`, built against the same header without the flag, agrees on the
  class layout. Fonts 2-8 only change the file-scope `const fontdata[]`
  table, which has internal linkage and a separate copy in each translation
  unit.
- **The guard alone is a no-op.** With the package patched and the flag
  removed, `wio_rgss_boot` (baseline) links to exactly the pre-change
  overflow, 684,008 bytes.
- **Real relinks.** All used the same `libmruby.a` pair from one
  `scripts/wio_bc2cpp_measure.bash /tmp/wio-flash-hunt` run, and each
  `pio run -e wio_rgss_boot` was serialized with `flock` against the other
  builds sharing this checkout:

  | build | before | after | delta |
  | --- | ---: | ---: | ---: |
  | `wio_rgss_boot` baseline, FLASH overflow | 684,008 | 669,112 | -14,896 |
  | `wio_rgss_boot` bc2cpp, FLASH overflow | 3,613,616 | 3,598,736 | -14,880 |
  | `wio` (P1 bring-up), flash used | 170,348 | 155,452 | -14,896 |
  | `wio_walk`, flash used | 72,464 | 57,568 | -14,896 |

  RAM is unchanged in every one: glyph tables are `.rodata`. `wio` and
  `wio_walk` both still build and link.

## What was not verified

- No boot under Renode or on real hardware. The `-E -dM` diff above is the
  basis for trusting that nothing on the display path changed: no pin, SPI or
  class-layout macro differs, and only code that draws fonts 2-8 is compiled
  out. `wio_walk`'s own text still uses font 1, which is kept.

## Consequences

- `wio_rgss_boot` needs about 14.9 KB less flash in both configurations.
  `wio` and `wio_walk` get the same saving, which is headroom they did not
  need. The firmware still does not fit (669,112 bytes over at baseline).
- docs/adr/0141's own reason for not touching TFT_eSPI, that it "would mean
  forking/patching a vendor library", is answered with a guarded, opt-in
  patch rather than a fork. The ~6 KB of driver code left in `TFT_eSPI.cpp.o`
  (Sprite, ellipse, triangle and the GLCD/GFXFF text paths) is still
  referenced through the vtable. Removing it would mean patching real code,
  not data, and was not attempted.
- The patch persists in `~/.platformio`. It is inert for any build that does
  not define `RPGMAKER_WIO_TFT_NO_EXTRA_FONTS`, and a reinstalled package is
  re-patched by the next wio build.
- If the Seeed package is ever updated so the five font lines are no longer
  consecutive, the script's assertion fails the build. Re-check the new
  `User_Setup.h` then, rather than dropping the assertion.
