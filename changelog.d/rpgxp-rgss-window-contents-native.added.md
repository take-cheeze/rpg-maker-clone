- **`RGSS::Window` now renders its contents natively.** `Window` was a pure-Ruby
  property holder; it is now native (`mruby-rgss/src/lib.cxx`): `Window.new` builds
  an `lv_canvas` the size of the window and blits the game's `contents` bitmap into
  the content area (inset 16px, scrolled by `ox`/`oy`) at `contents_opacity`, so
  window/menu/message **text actually shows** instead of being stored-but-ignored.
  `contents=`, `x=`/`y=`, `width=`/`height=`, `ox=`/`oy=`, `contents_opacity=`,
  `z=`, `visible`, `dispose` are native. The windowskin background/frame, the
  blinking cursor and the pause arrow are still stored-only — the next Window
  slice. First of the `Window`/`Tilemap` native renderers (after `Plane`). See
  `docs/rpgxp-rgss-api-gap.md`.
