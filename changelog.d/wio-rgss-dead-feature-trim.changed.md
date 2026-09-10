- **Wio Terminal: dropped RGSS features no Ruby path there can reach.**
  `RGSS::Plane` (a whole class -- RPG2000/2003 has no parallax-plane
  concept), `Bitmap#blur`/`#hue_change`/`#gradient_fill_rect`/
  `#radial_blur`/`#set_pixel`, `Tilemap.vx_tile_quads`/
  `.vx_table_leg_quads`, `Graphics.frame_reset`, `Kernel#zlib_inflate`,
  and `initialize_copy`/`Tone#gray=` on Bitmap/Color/Rect/Table/Tone --
  all either exclusive to `mruby-rpgxp`/`mruby-rpgvx` (not shipped on
  wio) or, for the `.dup`/`.clone` hooks, confirmed unused by checking
  every real `.dup`/`.clone` call site's actual receiver type. Wio-only
  (`#if !defined(WIO_TERMINAL)`); psp and the desktop build, which do
  ship XP/VX support, keep all of it. A separate idea -- dropping
  `LV_USE_LABEL` too, since no code calls `lv_label_*` outside two
  bring-up screens -- turned out not to work: LVGL's own `LV_USE_IMAGE`
  (genuinely needed for Sprite/Viewport zoom and rotation) hard-requires
  it, confirmed by a real build. See ADR 132.
  Real `pio run -e wio_rgss_boot` link: FLASH overflow 861,412 -> 842,344
  bytes (19,068-byte reduction).
