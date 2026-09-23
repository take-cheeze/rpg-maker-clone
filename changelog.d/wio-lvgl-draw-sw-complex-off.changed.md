- **Wio Terminal:** LVGL's complex software drawing (`LV_DRAW_SW_COMPLEX`:
  rounded corners, gradients, shadows, arcs, lines and masks) is now off on
  the board. Nothing there draws any of those, so this saves 13,040 bytes of
  flash with no change in rendering: a host render of an RGSS-shaped scene is
  byte-identical with the switch on and off. See `docs/adr/0201`.
