- **Wio Terminal: upgraded the build toolchain -- the single biggest real
  flash reduction in this whole shrink effort.** `env:wio`/
  `env:wio_rgss_boot` now pin a current Arm GNU Toolchain release (GCC
  14.2.1) instead of `atmelsam@9.0.0`'s own default (GCC 7.2.1, from 2017),
  via PlatformIO's `platform_packages` override. `-fno-ident` (drop the
  per-object GCC-version comment) and `-fmerge-all-constants` (more
  aggressive cross-file constant deduplication) are real, verified-bootable
  wins. `-Wno-implicit-function-declaration` was also needed: GCC 14 made
  that a hard error by default, which broke compiling Seeed's own vendored
  FreeRTOS library outright.
  Real, twice-reproduced `pio run -e wio_rgss_boot` link: FLASH overflow
  842,344 -> 684,080 bytes (158,264-byte reduction). See ADR 133 and, for
  why `-flto` (originally part of this same change) is not in that number,
  ADR 135.
