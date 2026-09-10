- New `tools/bc2cpp/profile_annotations.rb`: a dynamic, CRuby-based
  companion to `bc2cpp.rb`'s own `report_annotation_candidates`
  diagnostic. Runs the project's own real game-logic test harnesses
  (`scripts/rpg2k_logic_check.rb`, `scripts/rpg2k_scene_check.rb`, and
  others) with a `TracePoint(:call)` probe, records the real Ruby class
  of every candidate argument on every real call, and prints a
  ready-to-paste `# bc2cpp: (...)` magic-comment annotation wherever
  every observed call agreed it was Fixnum -- replacing "read the source
  and guess" with real evidence. Run for real: of 71 live candidates
  project-wide, 26 are confidently resolvable to `fixnum` from real
  observed calls; the rest are either genuinely not Fixnum-typed
  (confirmed, not guessed) or have zero real coverage in this
  environment (honestly reported as such, e.g. `LCF::Tree#initialize`'s
  arguments need a real `RPG_RT.lmt` this environment's test data
  doesn't include). See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s
  own follow-up for the full detail, including a real near-miss this
  caught that source-reading alone would have missed (an argument named
  `@state` that's actually `NilClass`/`Game::State`, never Fixnum).
