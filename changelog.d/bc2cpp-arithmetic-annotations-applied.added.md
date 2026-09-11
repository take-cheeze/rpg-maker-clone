- Applied 75 more real `# bc2cpp: (...)` argument-type annotations (92
  argument positions) to `mruby-rpg2k` source, this time evidence-backed
  by an opaque argument's direct use in fixnum-fastpath arithmetic/
  comparison ops rather than only an ivar write -- readability-focused
  (documents each method's real observed argument types right on the
  `def` line), since these never feed `bc2cpp`'s own ivar-embedding
  analysis. Spans `Game::Actor`/`Actors`/`EnemyAi`/`ChipSet`/`Map`/
  `Transition`/`Screen`/`Interpreter` and `RPG2k::Scene::Base`/`Battle`/
  `Order`/`SaveLoad`/`ItemMenu`/`Title`. `tools/bc2cpp/bc2cpp.rb`'s
  `report_annotation_candidates` and `profile_annotations.rb` extended
  to find and profile this class of candidate (also fixes a real
  `profile_annotations.rb` regex bug this surfaced: mixing named and
  plain capture groups silently makes the plain ones non-capturing).
  Verified zero compiled-output change (both already-shipped compiled
  targets re-checked byte-identical/line-number-echo-only; all four real
  CRuby test harnesses still pass). See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
