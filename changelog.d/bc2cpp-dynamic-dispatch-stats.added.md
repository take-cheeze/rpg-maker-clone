- `scripts/bc2cpp_coverage_report.rb` gains a new `-- dynamic dispatch
  remaining (real shipped build, SKIP_UNSUPPORTED=1) --` section in
  `docs/bc2cpp_coverage.txt`: total `mrb_funcall`/`mrb_funcall_with_block`
  call sites left in the whole program (split into `POLY`-marked --
  genuinely unavoidable, the receiver's real class isn't known even in
  principle -- vs. everything else, a name this compiler simply never
  attempted or failed to resolve MONO/TYPED), plus a top-30 histogram of
  the most-frequently dynamically-dispatched method names.

  Deliberately a SECOND, separate `bc2cpp.rb` invocation with `SKIP_
  UNSUPPORTED=1` set (the real flag every actual gem build sets), not a
  reuse of this script's own existing diagnostic-mode run: that first run
  deliberately never sets it (the `#error`-by-reason breakdown above needs
  the real `#error` TEXT, which `SKIP_UNSUPPORTED=1` strips entirely), so
  counting dispatch call sites off ITS OWN stdout would overcount --
  including real dispatch lines sitting inside a method that has an
  unrelated `#error` elsewhere in its own body and therefore never
  actually ships. A true "what does the shipped build actually contain"
  count needs the real, second run.

  Real numbers as of this round: 12757 total dynamic-dispatch call sites,
  5802 (45.5%) `POLY`-marked, 1084 distinct method names -- topped by
  `:[]` (1715), `:+` (609), `:-`/`:==` (551 each), `:*` (514), `:===`
  (504), `:new` (445), operator/indexing-dominated as expected (numeric
  and comparison ops on a statically-unproven receiver always fall to
  dynamic dispatch here). Adds roughly 2.5 minutes to a full regen (one
  extra whole-program compile) -- `bash scripts/bc2cpp_coverage_check.bash`
  and `MRBC=... ruby scripts/bc2cpp_coverage_report.rb` both still work
  exactly as before, just slower. `scripts/rpg2k_logic_check.rb` (1201
  checks), `scripts/rpg2k_scene_check.rb` (1062 checks), `scripts/
  lcf_testbed_check.rb` all still pass, unaffected (this is a reporting-
  only change, no `bc2cpp.rb` codegen touched).
