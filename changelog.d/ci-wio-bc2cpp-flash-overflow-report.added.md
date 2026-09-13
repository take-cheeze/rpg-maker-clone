- **CI now reports the `RPGMAKER_BC2CPP=1` Wio Terminal flash overflow.** A new
  `wio-bc2cpp` job builds `env:wio_rgss_boot` twice — baseline and bc2cpp —
  through `scripts/wio_bc2cpp_measure.bash` (the scripted form of the manual
  ADR 0142/0143 recipe: the nine mruby patches, the verified Unicode tables,
  the standalone ARM uni-algo, and two isolated `MRUBY_TARGET=wio` cross-builds)
  and posts `scripts/wio_overflow_report.rb`'s A/B table — section sizes, flash
  needed, the real overflow, % of the 507,904-byte budget, the `ld`
  cross-check and the delta, plus a per-object/archive breakdown — to the job
  summary. Advisory: the link overflowing is expected, so the job fails only if
  the cross-build or report tooling breaks. See `docs/adr/0152`.
