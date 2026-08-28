- **`Array#include?` no longer allocates a Proc on every call, engine-wide.**
  The headline find of this round: mruby's `Array` class has no native
  `#include?` of its own — there is no such entry in mruby's `src/array.c` or
  `mruby-array-ext` — so it falls through to `Enumerable#include?`
  (`self.each {|*val| return true if val.__svalue == obj }`), which allocates
  a Proc plus its closure env on *every single call*, however small the
  array or however early it returns. A per-condition-type
  `RGSS::Profiler.stats[:object_types]` pass tracing `Scene::Map
  #step_parallels`'s dominant remaining allocation cost down through
  `Game::Interpreter#do_conditional` → `#actor_condition` landed on
  `Game::Actor#state?`'s `@states.include?` — one of dozens of `.include?`
  call sites across the whole engine (skills, equipment, party membership,
  the RPG2000 interpreter's own command handlers, ...) that all pay the
  identical tax. Fixed once, for everything, with a plain index-loop
  `Array#include?` override in `mruby-rgss/mrblib/array_include.rb`
  (engine-wide like `array_sort.rb`'s `Array#sort`/`#sort!` fix beside it,
  not RPG2000-specific) — same ISO-15.3.2.2.10 `==`-based semantics, zero
  allocation.

- **`Game::Interpreter#range` returns the `Range` its two callers immediately
  rebuilt anyway, instead of a throwaway `[a, b]` Array.** Control
  Switches/Variables' shared range-resolver built a 2-element Array every
  single call — the dominant single source of interpreter-side per-command
  Array churn, per the same profiling pass — that both `#do_control_switches`
  and `#do_control_vars` immediately destructured and then reconstructed
  into `(a..b)` to iterate. `#range` now returns that `Range` directly, reused
  for the iteration rather than rebuilt; `#begin`/`#end` give a caller that
  still needs the two scalars separately (`#do_control_vars`'s own `a < b`
  check and range-variable split) the identical values. Both callers also
  skip the iteration itself for the overwhelmingly common single-target case
  (`a == b` — a plain `Var[5] = ...`, not a batch `Var[1..5] = ...`), which
  otherwise still paid a block's Proc+env for a one-element Range every call.

- **`Game::Party#include_actor?`/`#actor_by_id`/`#any_alive?` no longer use
  `#any?`/`#find` blocks** for the same reason, on the same call path
  (`#include_actor?` backs Conditional Branch's "actor in party"
  sub-condition) — plain `while` loops instead.

  Measured with the same temporary per-frame instrumentation used for this
  round's other fixes (reverted before commit), clean A/B on the identical
  deterministic Nepheshel run: **Array allocations 71.2 → 67.1 per frame,
  Proc 31.6 → 27.5, env 20.5 → 16.5** in this run's own capture window — and
  since `Array#include?` is engine-wide rather than scoped to whatever this
  one map's background Parallel Processes happen to poll, its real impact
  reaches every scene (menus, battle, every other `.include?` call site) this
  capture never exercises.

  Verified against `ctest -R mruby_test` (the one check that runs the real
  compiled mruby binary with `array_include.rb` loaded, covering every
  bundled gem's own test suite — mruby-rgss, mruby-rpg2k, mruby-rpgxp,
  mruby-rpgvx, mruby-mvjs alike), `scripts/rpg2k_command_soak.rb` (368,332
  real event commands across both Nepheshel variants), and the rest of the
  RPG2000 logic/render/scene checks — all pass, unchanged.
