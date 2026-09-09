# 114. Disable LVGL software-blend backends this build never selects

Date: 2026-09-09

## Status

Accepted

## Context

Continuing the search for omittable LVGL flash cost (ADR 112 already found
the built-in allocator was mostly a RAM red herring): the top live LVGL
objects after that fix are the `lv_draw_sw_blend_to_*` family --
`lv_draw_sw_blend.c` dispatches every fill/image blend with a runtime
`switch (layer_cf)` on the *destination layer's* color format, one case per
supported format, each pulling in its own backend object file
(`lv_draw_sw_blend_to_rgb565.c.o`, `..._to_argb8888.c.o`, `..._to_i1.c.o`,
etc). Every case in that switch is real, reachable code from the linker's
point of view -- `--gc-sections` can prove a whole function unreferenced,
not that a specific `case` inside a live function's `switch` is never
actually taken at runtime -- so every backend this project's `lv_conf.h`
leaves enabled (all ten -- LVGL defaults every `LV_DRAW_SW_SUPPORT_*` flag
to 1) links in full, regardless of which color formats this firmware's own
code ever actually constructs a layer in.

Each is individually gated by its own `LV_DRAW_SW_SUPPORT_<FORMAT>` flag in
`lv_conf.h` (both the backend's own `#include` and its `case` in the
dispatcher), so this is a real, per-format opt-out, not an all-or-nothing
choice.

## Decision

Grepped every real call site across `mruby-rgss/src/lib.cxx` (every
`lv_canvas_set_buffer`/`DataType<Bitmap>::alloc_obj` call, which is how
this engine's `RGSS::Bitmap` backs every on-screen surface) and
`mruby-rgss/src/wio.cxx` (the one `lv_display_set_color_format` call) for
which color formats this firmware ever actually requests:

| format | where | verdict |
| --- | --- | --- |
| `ARGB8888` | every `RGSS::Bitmap` canvas (`lib.cxx`, ~15 call sites) | used |
| `RGB888` | `bmp_init_file`'s opaque 3-channel decode path (`lib.cxx:1454`) -- a real path for any RPG Maker asset without an alpha channel, not test-only | used |
| `RGB565` | the display itself (`wio.cxx:86`, no swap call) | used |
| `A8` | never requested by app code, but LVGL's own font-glyph decoding (`lv_draw_label.c`, `lv_font_fmt_txt.c`, `lv_draw_sw_letter.c`) allocates A8 draw buffers internally for every glyph -- confirmed reachable, this app draws labels | used (keep) |
| `L8`, `AL88` | never requested by app code; referenced inside LVGL's own image/font mask-transform helpers (`lv_draw_sw_img.c`, `lv_draw_sw_transform.c`, `lv_draw_sw_utils.c`) in ways not fully traced to a concrete reachable call for this app's actual widget set | **not touched -- ambiguous**, left enabled |
| `I1` | never requested; the only internal check (`lv_refr.c:306`, `disp->color_format == LV_COLOR_FORMAT_I1`) compares against the display's own format, fixed to `RGB565` above | **unreachable** |
| `RGB565_SWAPPED` | never requested; the display never enables byte-swap | **unreachable** |
| `ARGB8888_PREMULTIPLIED` | never requested; every `RGSS::Bitmap` uses plain (non-premultiplied) `ARGB8888`, and nothing in this engine's own image loading produces the premultiplied variant | **unreachable** |

Disabled the three confirmed-unreachable backends in `app/wio/lv_conf.h`:

```c
#define LV_DRAW_SW_SUPPORT_I1 0
#define LV_DRAW_SW_SUPPORT_RGB565_SWAPPED 0
#define LV_DRAW_SW_SUPPORT_ARGB8888_PREMULTIPLIED 0
```

`L8`/`AL88` were deliberately left alone: unlike I1/RGB565_SWAPPED/
ARGB8888_PREMULTIPLIED (where the *only* place LVGL's own source
references the format is either dead for this config or trivially proven
so), L8/AL88 show up inside generic image-transform and mask-blend helper
functions whose actual reachability for this specific widget/font
combination was not traced all the way through -- disabling a format LVGL
actually needs at runtime would be a silent visual bug (missing glyph
pixels or a corrupted image blend), not a build failure, and this series'
own discipline is to not guess on that trade without being able to verify
it. A real follow-up, not ruled out -- just not done here.

### What was verified

- **A real, clean compile and relink** with all three backends off: no
  missing-symbol errors, confirming nothing in the actual link (not just
  this file's own guesswork) required `lv_draw_sw_blend_color_to_i1`/
  `..._rgb565_swapped`/`..._argb8888_premultiplied` or their `_image_to_`
  counterparts.
- **Every real color-format call site**, grepped directly rather than
  inferred: all `LV_COLOR_FORMAT_*` uses in `mruby-rgss/src/lib.cxx` and
  `wio.cxx` are accounted for in the table above.
- A real relink, `env:wio_rgss_boot`, on top of ADR 113's state (font SD
  offload now default): **1,130,212 -> 1,106,596**, 23,616 bytes of flash
  recovered (more than the three backends' own combined object size,
  ~15,439 bytes, since removing them also let the linker drop a few shared
  helper symbols only those three backends called). `.data`/`.bss`
  unchanged (150,224 bytes RAM used, 46,384 headroom) -- pure flash win, no
  RAM cost, as expected: these backends carry no static data of their own.

## Consequences

- Wio's flash overflow is 23,616 bytes smaller with no behavior change for
  anything this firmware actually draws: display flush (RGB565), every
  RGSS bitmap/canvas (ARGB8888), opaque decoded images (RGB888), and text
  (A8, internal to LVGL, untouched) all keep their backends.
- If a future feature ever needs a 1-bit canvas, a byte-swapped-RGB565
  display, or premultiplied-alpha image blending, these three lines in
  `app/wio/lv_conf.h` are exactly what to revert -- each is independent of
  the others and of `LV_DRAW_SW_SUPPORT_A8`/`RGB888`/`ARGB8888`/`RGB565`,
  which stay untouched.
- L8/AL88 remain open: the next flash-reduction pass on this port should
  either trace their reachability all the way through LVGL's font/image
  code for this exact `lv_conf.h` (confirming they're as dead as I1 turned
  out to be), or accept them as genuinely load-bearing and stop looking
  there.
