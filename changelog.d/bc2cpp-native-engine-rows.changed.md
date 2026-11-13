- The closed bc2cpp build also keeps native engine methods that only proven-receiver calls and C's `mrb_funcall`
  family look up as rows instead of method-table entries (`update` and `flash` of the RGSS sprites, viewports,
  windows and tilemaps, `snap_to_bitmap`, `to_nfd`, ...).
