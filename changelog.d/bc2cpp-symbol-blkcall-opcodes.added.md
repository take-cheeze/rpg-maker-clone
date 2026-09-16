- `tools/bc2cpp/bc2cpp.rb` now translates two more mruby opcodes: `SYMBOL`
  (`R[a] = intern(Pool[b])`, mrbc's compile-time string-to-symbol fold for
  each non-interpolated `%i[...]`/`%I[...]` word -- distinct from `LOADSYM`,
  which embeds an already-interned symbol directly and needs no pool
  lookup) via the same string-pool-literal mechanism `STRING`'s own case
  already used, and `BLKCALL` (`R[a] = R[a].call(R[a+1..a+b])`), mrbc's
  fast-path codegen for a bare `yield(...)`, always immediately preceded by
  a `BLKPUSH` fetching the method's own block. Confirmed against
  `src/vm.c`'s real interpreter that `BLKCALL` bypasses ordinary method
  dispatch entirely (no `#call`-by-name lookup, so a plain `mrb_funcall`
  substitute would be unsound for a non-Proc register); translated instead
  as an explicit `mrb_proc_p` check reproducing real `BLKCALL`'s own
  TypeError, followed by `mrb_yield_argv` (mruby's own public "run this
  block synchronously" API), which matches real `BLKCALL`'s self/target-
  class/break semantics for every real occurrence (an irep-backed Proc from
  a literal `do...end`/`{...}` block -- confirmed against all three real
  whole-program `BLKCALL` sites and every one of their real callers).
  Whole-program regen (`scripts/bc2cpp_coverage_report.rb`): `unhandled
  opcode SYMBOL` 6 -> 0, `unhandled opcode BLKCALL` 3 -> 0, `compiled clean`
  1969 -> 1972 (+3: `Game::Battle#apply_knockout_reset`, `RPG2k::Scene::Map
  #vehicle_blocks?`, and `RPG2k::Scene::Map#airship_landable?`, the last a
  downstream `SEND/SSEND splat` fix once its own `vehicle_blocks?` callee
  became analyzable), zero regressions (verified via a before/after
  clean-method-set diff, not just aggregate counts). `unhandled opcode
  BLKPUSH` stays at 3 (out of scope here) -- the three real `BLKCALL` sites
  (`Scene::Battle#cached_bitmap`, `Scene::Map#cached_bitmap`, `Scene::Map
  #page_field`) still have an unrelated `#error` from their own `BLKPUSH`
  and are not yet fully AOT-compiled end to end.
