# 132. Trim RGSS features unreachable on wio; LVGL's own label was not droppable

Date: 2026-09-10

## Status

Accepted

## Context

The previous session's per-component flash table (ADR 130's own real link)
showed `mruby-rgss` at 143,162 real linked bytes and `liblvgl.a` at 120,501 --
both large enough to ask whether either carries features wio's own Ruby
never reaches. Two separate investigations, with two different outcomes.

**RGSS**: `mruby-rgss/src/lib.cxx` registers its whole Ruby-visible API in
one file, shared by every target (wio, psp, the desktop build) that
depends on the gem. wio ships only `mruby-rpg2k` -- no `mruby-rpgxp`,
`mruby-rpgvx`, or `mruby-wolf` -- so any RGSS method whose only real
consumer is one of those un-shipped gems is *provably* unreachable on wio,
not just unused-in-practice. Cross-referencing all 161 `mrb_define_method`/
`mrb_define_class_method` registrations plus 14 module functions against
every real call in wio's own 14 shipped Ruby files found:

- **`RGSS::Plane`, the whole class (15 methods)** -- RPG2000/2003 event
  commands have no parallax-plane concept the way RPG Maker XP/VX does;
  nothing in `mruby-rpg2k` ever names `Plane`.
- **9 individually dead methods**: `Bitmap#blur`/`#hue_change`/
  `#gradient_fill_rect`/`#radial_blur`/`#set_pixel` (real code comments in
  `lib.cxx` name their actual consumers -- RPG::Cache's hue variants, "the
  stock scripts" -- and both are `mruby-rpgxp`-only, confirmed by grepping
  `mruby-rpgxp/mrblib/rgss_library.rb`, not shipped on wio), `Tilemap.
  vx_tile_quads`/`.vx_table_leg_quads` (VX-only by name), `Graphics.
  frame_reset`, `Kernel#zlib_inflate` (referenced only in a comment, in a
  file itself already wio-excluded).
- **5 `initialize_copy` (Bitmap/Color/Rect/Table/Tone) + `Tone#gray=`**,
  confirmed the harder way: `initialize_copy` fires implicitly from
  `.dup`/`.clone`, which no naive grep for the method name would catch.
  Exhaustively grepped every real `.dup`/`.clone` call across all 14 wio
  Ruby files instead (21 real call sites) and checked each one's actual
  receiver type -- every single one targets a plain `Array`/`String`, never
  a Bitmap/Color/Rect/Table/Tone. One near-miss worth recording: `@map_tint
  = tint.dup` in `scene/map.rb` looked like it might target `RGSS::Tone`
  from the name alone, but `Screen#tint` (`game.rb`) returns a plain
  `[r, g, b, sat]` Array, not a `Tone` -- confirmed by reading the method,
  not assumed from the variable name.

**LVGL**: `LV_USE_LABEL` (and the ~13.6 KB built-in Montserrat-14 font it
pulls in, the single largest object in all of `liblvgl.a`) looked droppable
too -- grepping every `lv_label_*` call found it used only by the two
bring-up screens' own status/key-echo text (`app/wio/src/main.cxx`,
`wio_rgss_boot_main.cxx`), never by the real RGSS render path (which draws
game text through this project's own shinonome/cp932 pipeline, not LVGL's).
**A real `MRUBY_TARGET=wio` build proved this wrong**: LVGL's own
`lv_image.h` hard-`#error`s when `LV_USE_LABEL` is off
(`"lv_img: lv_label is required. Enable it in lv_conf.h (LV_USE_LABEL 1)"`).
`LV_USE_IMAGE` is genuinely needed (Sprite/Viewport zoom and rotation go
through `lv_image_set_scale_x/y`/`_set_rotation`), so this is a real,
non-negotiable LVGL internal dependency, not an oversight in the earlier
measurement. A bring-up-screen rewrite (drop the two screens' own
`lv_label_*` calls in favor of a background-color signal + `Serial` output)
was drafted, then reverted once the font itself turned out unavoidable
regardless -- the two screens' own label calls are a few dozen bytes each,
not worth losing readable on-screen bring-up text for.

## Decision

**RGSS**: every dead item above is wrapped in `#if !defined(WIO_TERMINAL)`
in `mruby-rgss/src/lib.cxx` -- the function definitions, their
`mrb_define_method`/`mrb_define_class_method` registrations, and (for
`Plane` specifically) the one internal caller outside its own cluster:
`vp_refresh_children`'s per-object-kind dispatch had an
`else if (kind_of?(Plane)) plane_retile(...)` branch and its own
`plane_class` lookup, both now guarded the same way -- `Plane` can never be
`kind_of?` on wio (the class is never registered there), so the branch is
dead code, but leaving its *call site* unguarded while removing
`plane_retile`'s definition would have been a real link error. `psp` and
the desktop build (which do ship `mruby-rpgxp`/`mruby-rpgvx`, so `Plane`,
the VX quad methods, and the XP-only Bitmap effects are real features
there) get every one of these back unchanged -- confirmed with a real
`g++ -std=gnu++17 -fsyntax-only` pass on `lib.cxx` both with and without
`-DWIO_TERMINAL` defined, and a full real `MRUBY_TARGET=wio rake` +
`pio run -e wio_rgss_boot` link.

**LVGL**: no code change. `app/wio/lv_conf.h`'s own comment on
`LV_USE_LABEL` now records the `LV_USE_IMAGE` dependency and the real
build error that proved it, so a future session doesn't re-spend the same
investigation.

### What was verified

Real link, `pio run -e wio_rgss_boot`, same board budget as every prior ADR
in this series (507,904 usable flash bytes):

```
before (ADR 130): region `FLASH' overflowed by 861412 bytes
after:             region `FLASH' overflowed by 842344 bytes
```

**A real, confirmed 19,068-byte reduction** -- bigger than the sum of the
individually-measured dead functions (Plane-specific code alone was
~2,032 bytes measured in isolation via the map file; the other items summed
to ~4,124 more, ~6,156 total by the narrow per-symbol accounting). The gap
is real, not a measurement error: removing a whole registration cluster
(the `Plane` class's own `mrb_define_class_under`/`MRB_SET_INSTANCE_TT`
setup, its method-table entries, and whatever per-registration overhead
each one carries) recovers more than just the named functions' own
`.text` bytes.

RAM was essentially unaffected (`.bss` unchanged at 24,700 bytes; `.data`
moved from 12,256 to 12,992 bytes, noise from section layout shifting, not
a new allocation) -- expected, since every trim here is pure code, no
globals.

## Consequences

- **mruby-rgss is now genuinely wio-shaped**, not just wio-buildable --
  psp and desktop keep full RGSS (including XP/VX-only surface) unchanged.
  Any future RGSS method someone adds needs the same question asked: is
  this reachable from a gem wio actually ships?
- **The LVGL label idea is closed, not just deferred.** `LV_USE_IMAGE`
  requiring `LV_USE_LABEL` is an LVGL-version fact, not a configuration
  this project chose -- re-attempting it without changing away from
  `lv_image`'s zoom/rotation API entirely would hit the same `#error`.
- **This is the first ADR in the series to find its plan wrong mid-flight
  and catch it before shipping**, purely because a real compile was run
  rather than trusting the measurement from two turns prior. The reverted
  `main.cxx`/`wio_rgss_boot_main.cxx` diff never landed; nothing about
  those two files changed.
