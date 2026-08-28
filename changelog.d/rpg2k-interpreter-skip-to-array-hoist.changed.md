- **The RPG2000 event interpreter no longer allocates a throwaway Array on
  every Conditional Branch, Choice, Shop, Inn or Battle-handler skip.**
  `Game::Interpreter#skip_to`'s terminator-code lists were written as array
  literals at each of its 12 call sites, so a false Conditional Branch check —
  the standard shape of an always-on "poll a switch/variable in a Loop"
  background common event — allocated and discarded one every single time.
  Hoisted to frozen constants (`SKIP_TO_END_BRANCH`,
  `SKIP_TO_ELSE_OR_END_BRANCH`, ...), reused across calls. Found via the new
  `RGSS::Profiler.stats[:object_types]` per-type breakdown: on Nepheshel
  (5 always-on background Parallel Process common events), this was the
  single largest contributor to per-frame `Array` churn. Measured with a
  temporary per-frame instrumentation pass: **~250 to ~86 Array allocations
  per frame**, about a 65% cut. Verified against `scripts/rpg2k_command_soak.rb`
  (184,166 real event commands from Nepheshel) and the existing RPG2000 logic
  checks, all unaffected — this only changes what object backs the terminator
  list, never which commands run or how far `skip_to` scans.
