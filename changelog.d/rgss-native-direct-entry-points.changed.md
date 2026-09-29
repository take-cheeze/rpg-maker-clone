- **RGSS natives**: the `Rect`, `Sprite`, `Viewport`, `Plane`, `Tilemap` and
  `Window` setters and getters that compiled code calls most (`x=`, `y=`, `z=`,
  `visible=`, `color=`, `contents=`, `windowskin=`, `cursor_rect=`, `active=`,
  `pause=`, `width=`, `height=`, `flash`, `tone`) now have shared
  frame-independent `rgss::*_direct` entry points. Each
  `mrb_define_method` binding unpacks its arguments and forwards to the same
  function, so behaviour (including the `RGSSError` on a disposed object) is
  unchanged. The Window, Tilemap and Plane entry points have link-only stubs on
  the Wio Terminal build, which also fixes that build's compile of
  `window_update_direct` and its siblings.
