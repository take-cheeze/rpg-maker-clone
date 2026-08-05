- **MZ plays animations.** The one in-game system nothing exercised, and MZ has
  two of them: `Spriteset_Base.isMVAnimation` routes by data shape, sending an
  animation that carries a `frames` array to `Sprite_AnimationMV` (plain sprite
  cells out of a sheet) and everything else to `Sprite_Animation`, which needs
  the Effekseer WASM runtime `main.js` starts and this host does not. So the
  sprite-sheet path is the reachable one — it turns out to work end to end
  through the WebGL backend, including the per-sprite blend modes nothing else
  in the test bed asks for. `data/mz-sample` now authors an MV-format burst
  (`scripts/gen-mz-sample.py`), `--mz_animation_test` plays it on the player
  through the same `$gameTemp.requestAnimation` an event's Show Animation
  command calls, and `MZ_MODE=animation` asserts `mv=true played=true` plus, in
  the frame check, that the burst is actually in the picture. That last part
  earns its place: with the animation's art file renamed away the log still
  reports `played=true` — the cell sprite is visible and carries the host's
  placeholder bitmap — and only the frame check notices nothing drew.
