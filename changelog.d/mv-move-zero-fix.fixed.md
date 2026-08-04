- MV movement smoke test (`--mv_move_test`) now actually walks the player.
  The probe called `Integer#zero?`, but this mruby build omits
  `mruby-numeric-ext` (kept lean for the embedded targets), so `#zero?` is not
  defined and the call raised `undefined method 'zero?' for Integer` every
  frame — aborting the probe before it ever pressed a direction, so the player
  never moved. Rewritten as `== 0`. The same latent `Integer#zero?` call in
  RPG2000's `Tone#update_tint` (which would have raised mid-tint on the native
  binary) is fixed the same way.
