- The RPG2000 message window now shows the classic blinking arrow at the
  bottom-centre of the window while it's waiting on the player: once the text
  has fully typed out (or hits a `\!` wait code), `Scene::Map` sets
  `RPG2k::Window#pause` and drives its per-frame `update`. `RPG2k::Window`
  (its own composited widget, distinct from `RGSS::Window`) gained the arrow
  itself -- a fourth sprite layer blitted from the System windowskin (source
  rect and 20-frame blink cadence ported from a reference implementation,
  absent a real RPG_RT frame in this repo to measure
  against) -- since nothing drew it before (#447).
