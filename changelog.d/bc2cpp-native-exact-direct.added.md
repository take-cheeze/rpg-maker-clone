- **bc2cpp:** a send to an RGSS native whose receiver is proven exact -- a stable
  class or module constant (`RGSS.mouse_x`, `RGSS.window_title=`,
  `Bitmap._decoder_ran?`), or `self` of an exact class or of a class or module
  object's own method -- now calls the native's frame-independent entry point
  with no receiver guard and no dispatch fallback (`NATIVE_EXACT_DIRECT`). Only
  names spelled solely by the RGSS sources, registered once on the owner, that no
  Ruby definition, alias, visibility change, mixin or dynamic installer touches.
  Covered by `scripts/bc2cpp_constant_singleton_check.rb`.
