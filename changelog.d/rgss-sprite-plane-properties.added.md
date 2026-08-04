- **RGSS `Sprite` / `Plane` properties.** `RGSS::Sprite` now stores the extended
  properties the stock RGSS scripts set — `opacity`, `ox`/`oy`, `zoom_x`/`zoom_y`,
  `angle`, `mirror`, `tone`, `color`, `blend_type`, `bush_depth`, `src_rect` and
  `flash` — with RGSS defaults, and `RGSS::Plane` becomes a full property holder
  (`bitmap`, `ox`/`oy`, `opacity`, `visible`, `z`, `zoom`, `blend_type`, `tone`,
  `color`, `dispose`). This lets the script host (ADR 0017) run scripts that drive
  these without raising; honouring them in the native renderer is tracked in
  `docs/rpgxp-rgss-api-gap.md`. Covered by `mruby-rgss/test`.
