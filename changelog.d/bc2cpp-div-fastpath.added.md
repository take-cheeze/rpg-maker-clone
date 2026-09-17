- `tools/bc2cpp/bc2cpp.rb`'s `DIV` opcode (`Integer#/`) now gets the same
  fixnum/fixnum runtime-guarded fast path `ADD`/`SUB`/`MUL` already have,
  closing the one gap those three left open on purpose: real integer
  division floors toward negative infinity, not C's own truncating `/`,
  and this file's own earlier round punted on replicating that rounding
  by hand rather than risk getting it subtly wrong.

  Turns out nothing needs replicating: `int_div` (the real `Integer#/`
  native implementation, 3rd/mruby/src/numeric.c) itself calls a real,
  already-public API for exactly the plain-Integer/plain-Integer case --
  `mrb_div_int_value(mrb, mrb_integer(x), mrb_integer(y))` -- confirmed
  by reading `int_div` directly, not assumed from the function's name.
  Calling that same function here (an `extern "C"` forward declaration,
  exactly like the existing `mrb_str_aref` one -- `mruby/internal.h` has
  no `MRB_BEGIN_DECL`/`MRB_END_DECL` guard either) reproduces `Integer#/`'s
  real rounding AND its real `ZeroDivisionError`/overflow raises exactly,
  not an approximation -- the same "call mruby's own real implementation
  function directly" substitution `GETIDX`'s own String arm already makes
  for `mrb_str_aref`. Same fixnum/fixnum guard `ADD`/`SUB`/`MUL` already
  use (no bigint check, matching their own established precedent),
  `mrb_funcall` fallback for anything else (Float, a user `#/` override,
  a real Bignum).

  Verified three ways: (1) the underlying floor-division-from-truncating-
  division correction formula (`div -= 1 if (x^y) < 0 && x != div*y`)
  checked against real Ruby `/` semantics for 10 real positive/negative
  cases including every sign combination -- all match. (2) `nm` on the
  real built `libmruby.a` confirms `mrb_div_int_value` is a real,
  externally-linked (`T`) symbol. (3) inspected the real generated code
  for several whole-program `DIV` sites directly -- the guard/fastpath/
  fallback shape emits correctly everywhere. A real runtime link test
  (constructing both paths' results via a real `mrb_state` and comparing)
  was attempted but blocked by an unrelated pre-existing link failure in
  this sandbox (missing quickjs symbols from the `mruby-mvjs` gem, nothing
  to do with this change) -- the `g++ -std=c++17 -fsyntax-only` smoke test
  and the three checks above stand in for it. This change does not move
  the `docs/bc2cpp_coverage.txt` `#error`/dispatch-count totals at all
  (by design: every `DIV` site already compiled via `mrb_funcall`, and
  still emits exactly one `mrb_funcall(..., "/", ...)` line each -- now
  inside the fallback branch of a guard, the same "still counted, now
  rarely taken at runtime" shape `ADD`/`SUB`/`MUL`/comparison already
  have in that same report). `scripts/rpg2k_logic_check.rb` (1201
  checks), `scripts/rpg2k_scene_check.rb` (1062 checks), `scripts/
  lcf_testbed_check.rb` all still pass.
