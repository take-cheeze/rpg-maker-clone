- **Corrected docs/adr/0142's `RPGMAKER_BC2CPP=1` `wio_rgss_boot` flash/RAM
  measurement**, which it turns out was run against a stale build reflecting
  only 55 of bc2cpp's real, current 1,573 compiled methods (7/17/31 vs the
  real 34/82/1,457 across `mruby-lcf-compiled`/`mruby-rgss-compiled`/
  `mruby-rpg2k-compiled`). A provably clean re-measurement (fresh submodule
  checkout, all nine `patches/*.patch` reapplied, Unicode tables re-verified
  against `flake.nix`'s pins, late-round symbols positively confirmed present
  in the real `register.o`) finds the real flash delta is +1,067,524 bytes
  (675,960 -> 1,743,484 bytes over the 507,904-byte budget) — similar in
  absolute size to 0142's stale +1,045,440, but for 28.6x more method
  coverage; real static RAM is still unchanged. 0142's own "one gem is a
  100x-outlier, specifically inefficient" conclusion does not hold once the
  real, current method count is used as the denominator. See
  `docs/adr/0143-bc2cpp-real-wio-flash-ram-remeasurement-at-full-scope.md`.
