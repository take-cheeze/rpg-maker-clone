- **`RGSS::Tilemap` now honours tile priority (interim).** `priorities=` is native
  and routes each tile by its `priorities[id]`: priority-0 tiles into the ground
  canvas and priority ≥ 1 tiles into a second "above" canvas — a companion
  z-ordered object (torn down by the native `Tilemap#dispose`) that sorts above the
  character sprites — so roofs and tree crowns draw over the party instead of being
  overdrawn. This is an interim flat approximation of RMXP's per-row priority (it
  puts every priority tile above every character, and the above layer's `z` is a
  best guess pending in-game confirmation); the per-row scheme is designed in
  `docs/adr/0022-rpgxp-tilemap-priority-layering.md`. See
  `docs/rpgxp-rgss-api-gap.md`.
