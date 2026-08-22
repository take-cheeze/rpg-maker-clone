- **`Graphics.brightness=`/`fadeout`/`fadein`** now actually darken the
  screen instead of only tracking the value. VX/VX Ace already faded visibly
  through `@viewport3.color`, but RMXP's own stock scripts (`Scene_Gameover`,
  `Scene_End`, several post-battle screens) call `Graphics.fadeout`/`fadein`
  directly, and previously saw no visual change at all. Drawn with the same
  full-screen overlay technique `Graphics.transition` already uses for its
  own dissolve. `fadeout`/`fadein` also now step one frame at a time instead
  of running all their frames first and jumping to the end value.
