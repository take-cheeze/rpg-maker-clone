- **bc2cpp closed-world builds now fail on an unreviewed dead fallback.** On
  psp/wio/maix, a guard-chain fallback that the closed world proves no class
  can answer (a `bc2cpp_nomethod` site, ADR 0210) aborts the compiled gem's
  codegen unless `tools/bc2cpp/nomethod_reviewed.rb` lists it. The build also
  fails when a listed entry is no longer a dead site. The 52 current sites
  (13 in `mruby-lcf-compiled`, 39 in `mruby-rpg2k-compiled`; 38 keys) were
  each read and are all unreachable `self` calls; none hides a missing method.
  The runtime raise stays in place as a safety net.
  `scripts/bc2cpp_nomethod_reviewed_check.rb` re-proves the list on every CI
  run, and `scripts/bc2cpp_nomethod_reviewed_update.rb` regenerates it. See
  ADR 0226.
