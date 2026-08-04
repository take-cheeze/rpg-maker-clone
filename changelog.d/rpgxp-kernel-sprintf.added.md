- **`Kernel#sprintf` / `#format` / `String#%`.** Added the `mruby-sprintf` core
  gem to the build so the RGSS script host (ADR 0017) can run the stock scripts
  that format numbers (`%02d` clocks, `%04d` ids, `%+d`, `%0*d`). Covered by the
  gem's own tests and a `mruby-rpgxp/test` availability check; tracked in
  `docs/rpgxp-rgss-api-gap.md`.
