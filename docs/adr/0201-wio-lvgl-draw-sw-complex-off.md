# 201. Turn off LVGL's LV_DRAW_SW_COMPLEX on the Wio Terminal

Date: 2026-09-22

## Status

Accepted

## Context

After docs/adr/0199 and 0200, `liblvgl.a` is still 107,671 bytes of the
`wio_rgss_boot` image. `app/wio/lv_conf.h` has already dropped every widget
but canvas/image/label (docs/adr/0132), every theme, and three unused
blend-target color formats (docs/adr/0114). It still leaves one draw-side
switch at LVGL's default: `LV_DRAW_SW_COMPLEX 1`.

That switch gates the software renderer's non-rectangular work. It covers
rounded corners (`radius`, `clip_corner`), gradients, box shadows, arcs,
lines, triangles, radius borders, and the `lv_draw_sw_mask` engine these all
share. Their linked cost in the current map: `lv_draw_sw_mask.c.o` 3,656,
`lv_draw_sw_box_shadow.c.o` 3,172, `lv_draw_sw_line.c.o` 1,581,
`lv_draw_sw_border.c.o` 1,282, `lv_draw_sw_arc.c.o` 1,226,
`lv_draw_sw_fill.c.o` 970 (its complex half), `lv_draw_sw_triangle.c.o` 962
and `lv_draw_sw_mask_rect.c.o` 366. The draw dispatcher references every one
of these, so `--gc-sections` cannot drop them.

Nothing on this board reaches them:

- Every LVGL call in `mruby-rgss/src/lib.cxx`, `wio.cxx` and the two
  bring-up sketches was enumerated. It is canvases, `lv_image`
  scale/rotation/pivot, `lv_obj_set_style_opa`,
  `lv_obj_set_style_blend_mode`, `bg_color`/`bg_opa`, `text_color`, labels,
  snapshots, positioning, and flags. There is no `radius`, gradient, shadow,
  border, outline, arc, line or triangle, and no mask API.
- No theme is compiled in (`LV_USE_THEME_DEFAULT 0`), so no object picks up a
  radius or shadow implicitly. mruby-rgss also calls
  `lv_obj_remove_style_all()` on the containers it creates.
- Image transforms (`lv_draw_sw_transform.c`) and blend modes are outside
  this switch. In `lv_draw_sw_img.c` the switch only guards the
  rounded-corner image path.

## Decision

Set `#define LV_DRAW_SW_COMPLEX 0` in `app/wio/lv_conf.h`, with a comment
recording the reasoning above. It is scoped to Wio only: desktop, PSP, maix
and m5stack each have their own `lv_conf.h`, and none of them change.

The public headers mruby-rgss's `lib.cxx` includes do not depend on this
switch. Only `lv_global.h`'s private circle cache and the mask headers do,
and `lib.cxx` includes neither. So libmruby.a (which compiles against this
same `lv_conf.h`) and PlatformIO's liblvgl cannot disagree on a layout that
matters.

## What was verified

- **Rendering, not just linking.** LVGL was built on the host twice from the
  repo's vendored `3rd/lvgl` with this exact `lv_conf.h`, once with
  `LV_DRAW_SW_COMPLEX 0` and once with `1`. Both rendered the same scene,
  shaped like what mruby-rgss builds:
  - ARGB8888 canvases with per-pixel alpha
  - one canvas rotated 45 degrees and scaled non-uniformly
  - one at opa 128 with additive blending
  - one subtractive, rotated, and partly off-screen
  - a scroll-disabled, style-free clipping container with an
    overflow-visible child (the Viewport structure)
  - a label drawn in unscii 8 (docs/adr/0200)
  - a semi-transparent filled box

  An `lv_snapshot_take` of the screen was **byte-identical** between the two
  builds. As a sensitivity check, giving the box a 10 px radius makes the
  two snapshots differ: the COMPLEX-off build refuses to draw it, as LVGL's
  own `Can't draw complex rectangle` path says. So the harness does detect
  complex-path use; this scene just has none.
- **Real relinks**, `flock`-serialized, on top of docs/adr/0200, using the
  same `libmruby.a` pair:

  | build | before | after | delta |
  | --- | ---: | ---: | ---: |
  | `wio_rgss_boot` baseline, FLASH overflow | 656,808 | 643,768 | -13,040 |
  | `wio_rgss_boot` bc2cpp, FLASH overflow | 3,586,440 | 3,573,400 | -13,040 |
  | `wio` (P1 bring-up), flash used | 143,148 | 130,108 | -13,040 |

  `liblvgl.a` goes from 107,671 to 94,634 bytes. RAM drops by 112 bytes
  (`lv_global_t`'s circle cache).

## What was not verified

- No boot on real hardware or under Renode, since none is available here.
  The host render uses the same LVGL sources and config, but is not the
  device's own RGB565 flush.
- The host scene covers the RGSS operations the code uses today. It is not
  proof for a future feature: a Window skin with rounded corners drawn
  through LVGL styles, a gradient, or a primitive line/arc would silently
  not draw. RGSS's own drawing (Bitmap `fill_rect`, `gradient_fill_rect`,
  window skins, text) is done in software inside mruby-rgss into canvas
  buffers, not through LVGL styles, so this constrains only new
  LVGL-style-based code.

## Consequences

- Cumulative with docs/adr/0199 and 0200, `wio_rgss_boot`'s baseline FLASH
  overflow goes 684,008 -> 643,768 (-40,240), and bc2cpp goes 3,613,616 ->
  3,573,400 (-40,216).
- Anyone who adds LVGL radius, gradient, shadow, line or arc drawing for Wio
  has to flip this switch back. LVGL logs a warning in that case (with
  `LV_USE_LOG` on) instead of failing to build, which is why the reason is
  recorded both here and in the `lv_conf.h` comment.
