- MV mouse / touch input: the pointer now drives MV's `TouchInput`, so title
  and menu items are clickable. The SDL window backend's event watch captures
  mouse motion and the left button (`src/sdl_input.cxx`), buffers them in
  `mruby-rgss` (`input_bridge.cxx`) and exposes them as
  `RGSS::Input.mouse_x` / `mouse_y` / `mouse_pressed?`; each frame `MV#sync_touch`
  pushes a sample into `TouchInput` — setting `_x`/`_y` and feeding `_newState`
  the triggered/moved/released edges MV's DOM handlers would — so its windows'
  `isTriggered`/`isPressed` hit-testing works. Coordinates are 1:1 canvas pixels
  (MV renders un-zoomed). The bridge mapping is unit-tested
  (`mruby-mvjs/test/touch_test.rb`); non-SDL backends report the pointer at the
  origin, unpressed.
