- **Wio Terminal: upgraded the build toolchain and enabled link-time
  optimization -- by far the single biggest flash reduction in this
  whole shrink effort.** `env:wio`/`env:wio_rgss_boot` now pin a current
  Arm GNU Toolchain release (GCC 14.2.1) instead of `atmelsam@9.0.0`'s own
  default (GCC 7.2.1, from 2017), via PlatformIO's `platform_packages`
  override -- the older compiler made `-flto` fail outright with a real
  link error, a 64-bit-division helper LTO's own codegen only discovers
  it needs after normal library resolution has already run. `-flto`,
  `-fno-ident` (drop the per-object GCC-version comment), and
  `-fmerge-all-constants` (more aggressive cross-file constant
  deduplication) are now real. `-Wno-implicit-function-declaration` was
  also needed: GCC 14 made that a hard error by default, which broke
  compiling Seeed's own vendored FreeRTOS library outright.
  Real, twice-reproduced `pio run -e wio_rgss_boot` link: FLASH overflow
  842,344 -> 651,824 bytes (190,520-byte reduction), plus a real ~5.8 KB
  RAM reduction. See ADR 133.
