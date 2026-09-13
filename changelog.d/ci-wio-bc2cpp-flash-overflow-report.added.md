- **CI now reports the `RPGMAKER_BC2CPP=1` Wio Terminal flash overflow.** A new
  `wio-bc2cpp` job builds `env:wio_rgss_boot` twice — baseline and bc2cpp —
  through `scripts/wio_bc2cpp_measure.bash` (the scripted form of the manual
  ADR 0142/0143 recipe: the nine mruby patches, the verified Unicode tables,
  the standalone ARM uni-algo, and two isolated `MRUBY_TARGET=wio` cross-builds)
  and posts `scripts/wio_overflow_report.rb`'s A/B table — section sizes, flash
  needed, the real overflow, % of the 507,904-byte budget, the `ld`
  cross-check and the delta, plus a per-object/archive breakdown — to the job
  summary. Advisory: the link overflowing is expected, so the baseline build is
  the only fatal part — a bc2cpp build failure is reported in the summary
  instead (bc2cpp's generated code currently fails to compile on the CI runners,
  a separate codegen bug). The cross build's `mrbc`-only host
  build now skips the AOT-compiled gems (`MRUBY_BC2CPP_SKIP_HOST`, set by the
  measure script): compiling ~1,500 generated methods for a build that only
  exists to produce `mrbc` is wasted work, and unset (the default) the
  desktop/wasm builds still compile them. See `docs/adr/0152`.
