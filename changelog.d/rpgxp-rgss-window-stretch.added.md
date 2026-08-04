- **`RGSS::Window#stretch` is now honoured.** With the default (`true`) the 128×128
  windowskin background tile is stretched over the whole window as before; setting
  it `false` tiles that background at 1:1, repeating it across the window (edge
  tiles clip against the canvas), matching RMXP. `stretch=` is native and re-renders
  on assignment. See `docs/rpgxp-rgss-api-gap.md`.
