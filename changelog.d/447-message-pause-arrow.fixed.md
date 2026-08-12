- The RPG2000 message window now shows the blinking pause arrow while it's
  waiting on the player: once the text has fully typed out (or hits a `\!`
  wait code), `Scene::Map` sets the window's native `pause` flag and drives
  its per-frame `update`, so the already-implemented windowskin pause-arrow
  drawing (`window_refresh` in `mruby-rgss/src/lib.cxx`) actually renders and
  animates instead of never being turned on (#447).
