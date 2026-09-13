- **CI now reports the `RPGMAKER_BC2CPP=1` Wio Terminal flash overflow.** A new
  `wio-bc2cpp` job builds `env:wio_rgss_boot` twice — baseline and bc2cpp —
  through `scripts/wio_bc2cpp_measure.bash` (the scripted form of the manual
  ADR 0142/0143 recipe: the nine mruby patches, the verified Unicode tables,
  the standalone ARM uni-algo, and two isolated `MRUBY_TARGET=wio` cross-builds)
  and posts `scripts/wio_overflow_report.rb`'s A/B table — section sizes, flash
  needed, the real overflow, % of the 507,904-byte budget, the `ld`
  cross-check and the delta, plus a per-object/archive breakdown — to the job
  summary. Advisory: the link overflowing is expected, so the job fails only if
  the cross-build or report tooling breaks. The cross build's `mrbc`-only host
  build now skips the AOT-compiled gems (`MRUBY_BC2CPP_SKIP_HOST`, set by the
  measure script): compiling them there is wasted work, and the host GCC some
  CI runners ship rejects the generated C++ — the wio target still compiles
  them, and unset the desktop/wasm builds do too. See `docs/adr/0152`.
