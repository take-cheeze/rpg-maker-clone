- Fixed a real gap in RPG Maker MZ's Effekseer diagnostic stub
  (`mruby-mvjs/mrblib/mz.rb`): it defined `init()` but not the
  `setRestorationOfStatesFlag()` method real `effekseer.min.js` also
  exposes, which `rmmz_core.js`'s `Graphics._createEffekseerContext` calls
  right after `init()` unconditionally. The resulting `TypeError` was
  swallowed by that function's own `try/catch`, which resets
  `Graphics._app` to `null` on any exception -- so MZ boot failed with a
  generic "Failed to initialize graphics." one call later, with nothing
  pointing at Effekseer. Found against a real downloaded MZ game
  (Labyria), which never got past this. Fixed by adding the missing
  no-op method, alongside the stub's other no-ops
  (`beginDraw`/`endDraw`/`setProjectionMatrix`); the game now boots clean
  through the title and every headless probe (move, message, menu, save,
  audio, battle).
