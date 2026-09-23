# 200. Switch the Wio Terminal's LVGL default font from Montserrat 14 to unscii 8

Date: 2026-09-22

## Status

Accepted

## Context

After docs/adr/0199, the largest single object in `liblvgl.a` on the
`wio_rgss_boot` image is `lv_font_montserrat_14.c.o`, at 13,641 bytes:

| section | bytes |
| --- | ---: |
| `.rodata.glyph_bitmap` (4 bpp anti-aliased) | 8,832 |
| `.rodata.kern_class_values` | 2,989 |
| `.rodata.glyph_dsc` | 1,264 |
| rest (cmaps, kern classes, font struct) | 556 |

docs/adr/0132 already showed the label widget cannot be removed: LVGL's own
`lv_image.h` `#error`s without `LV_USE_LABEL`, and RGSS `Sprite`/`Viewport`
need `lv_image`. That ADR stopped there, and kept the two bring-up screens'
labels because readable on-screen text was worth "a few dozen bytes each".

The label code is one question. The face it draws with is a separate one.
Every LVGL text draw on this board is a short ASCII status or key-echo
string on those two bring-up screens (`app/wio/src/main.cxx`,
`app/wio/src/wio_rgss_boot_main.cxx`), for example
`"rpg2k on Wio Terminal\nreal mruby+RGSS boot"`, `"Keys: Up A"`, and an
exception class name. Real game text never touches an `lv_font_t`: it is
rendered by mruby-rgss's shinonome/cp932 pipeline. `grep` for
`lv_font`/`LV_FONT`/`LV_SYMBOL` across `mruby-rgss/src` and `app/wio/src`
finds nothing. So of Montserrat 14 the board uses 4 bpp anti-aliasing,
kerning, and ~60 FontAwesome `LV_SYMBOL_*` glyphs that no string here
contains.

## Decision

`app/wio/lv_conf.h`: `LV_FONT_MONTSERRAT_14 0`, `LV_FONT_UNSCII_8 1`,
`LV_FONT_DEFAULT &lv_font_unscii_8`. unscii 8 is LVGL's own bundled 1 bpp,
8x8, printable-ASCII face. It covers every character these labels can
contain, including the exception class names, which are Ruby constant names.
The labels stay on screen and stay legible. They are just smaller (8 px
instead of 14 px) and not anti-aliased. For a bring-up and measurement
screen that is an acceptable trade; for a game UI it would not be, but no
game UI draws through LVGL's font.

The same edit corrects `lv_conf.h`'s own `LV_USE_LABEL` comment. It said the
bring-up screens had been "rewritten to a background-color signal + Serial
output" and no longer called `lv_label_*`. docs/adr/0132 records that rewrite
as drafted and reverted, and both screens still call `lv_label_create`.

## What was verified

Real relinks, `flock`-serialized, on top of docs/adr/0199, using the same
`libmruby.a` pair (`scripts/wio_bc2cpp_measure.bash`):

| build | before | after | delta |
| --- | ---: | ---: | ---: |
| `wio_rgss_boot` baseline, FLASH overflow | 669,112 | 656,808 | -12,304 |
| `wio_rgss_boot` bc2cpp, FLASH overflow | 3,598,736 | 3,586,440 | -12,296 |
| `wio` (P1 bring-up), flash used | 155,452 | 143,148 | -12,304 |

Checked in the map: `lv_font_montserrat_14.c.o` (13,641) is gone and
`lv_font_unscii_8.c.o` (1,342) takes its place. The shared
`lv_font_fmt_txt.c.o` renderer is unchanged at 1,196 bytes. RAM is
unchanged. `env:wio_walk` links no LVGL and is unaffected.

libmruby.a's objects compile against this same `lv_conf.h` (through
`RGSS_WIO_ARDUINO_INCLUDES`). The font switches only gate `extern`
declarations in `lvgl.h`, not any struct layout, and nothing in mruby-rgss
names a font. The relink against a `libmruby.a` built with the old setting
resolved every symbol.

## What was not verified

- Not rendered on real hardware or under Renode: no Renode binary is
  available in this environment. unscii 8 goes through the same
  `lv_font_fmt_txt` glyph path Montserrat does, so this is a data change,
  not a new code path. A first boot on real hardware should still confirm
  that the status text looks as expected.

## Consequences

- About 12.3 KB less flash for `wio` and `wio_rgss_boot`, in both
  configurations. Cumulative with docs/adr/0199, `wio_rgss_boot`'s baseline
  overflow goes 684,008 -> 656,808 (-27,200).
- If the LVGL font ever renders something beyond ASCII status text (a
  localized UI, icons), revisit this: pick a subset font generated for the
  real strings rather than going back to the full Montserrat 14.
