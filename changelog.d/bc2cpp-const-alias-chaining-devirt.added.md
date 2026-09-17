- `tools/bc2cpp/bc2cpp.rb`'s `INTEGER_CONSTANT_PROOF` learns to follow a
  constant whose definition is itself another constant
  (`CONST_ALIAS_CHAINING`), the first of the two open items the previous
  round measured and deliberately left on the table. On the real shipped
  whole-program build (`SKIP_UNSUPPORTED=1`, the same output
  `scripts/bc2cpp_coverage_report.rb` scans) this takes
  `mrb_funcall`/`mrb_funcall_with_block` call sites from 13993 to 13870 --
  123 removed -- and the proven-constant set from 669 names to 693. The
  `// operands proven Fixnum` marker count in the generated C++ goes
  357 -> 480.

  Direction chosen by re-running the previous round's own methodology
  rather than by taking its suggestion on faith: a one-off instrumented
  build tagging every refusal inside `proven_fixnum_operand?` across all
  7081 whole-program `proven_fixnum_pair?` queries (6399 failing), then a
  ceiling run per refusal reason with that reason forcibly disabled. The
  ranking that matters is not raw refusal count but COSTLY count -- a
  refusal only costs a real call site when the OTHER operand proves -- and
  the measured ceilings (sites removed against the 13993 baseline) came
  out: every SEND-family result treated as Fixnum 729, every entry
  argument 421, every ivar 222, every `GETIDX`/`AREF` 218, dominance
  lifted entirely 173, every constant 159, only `size`/`length` 109, every
  `GETUPVAR` 35. The three biggest are all whole-program return-type or
  argument-type inference, each a materially larger mechanism with its own
  soundness argument; the constant ceiling was the largest one reachable
  by a bounded, self-contained extension, and this change captures 123 of
  its 159.

  What the refusal instrumentation actually pointed at was unambiguous.
  Tallying the bare constant name behind every `src_GETCONST`/
  `src_GETMCNST` refusal put `TILE` first at 134, then `SCREEN_W` 105,
  `SCREEN_H` 55, `VISIBLE_ROWS` 30, `COLS` 30, `ARROW_BLINK_FRAMES` 20,
  `ARROW_W` 16, `HEADER_H` 16, `ARROW_H` 12 -- and the top three are pure
  aliases, not computed values. This is the dominant idiom in this
  codebase: a scene class re-exports the handful of layout numbers it
  uses, so `SCREEN_W = RPG2k::WIDTH` appears verbatim in eleven separate
  scene files (`scene/map.rb`, `menu.rb`, `battle.rb`, `item_menu.rb`,
  `equip_menu.rb`, `skill_menu.rb`, `status_menu.rb`, `save_load.rb`,
  `debug_menu.rb`, `order.rb`, ...), `ARROW_W = Window::ARROW_W` in five,
  and `TILE = Game::TILE` heads `Scene::Map`.

  The real bytecode, from `mrbc -v` rather than assumed: `TILE =
  Game::TILE` is `GETCONST R1 Game` / `GETMCNST R1 (R1)::TILE` /
  `SETCONST TILE R1`, and `SCREEN_W = RPG2k::WIDTH` is `GETCONST R1
  RPG2k` / `GETMCNST R1 (R1)::WIDTH` / `SETCONST SCREEN_W R1`. So the
  backward walk from the `SETCONST`'s source register lands on a
  `GETCONST`/`GETMCNST`, which the old `literal_int_const_source?`
  classified as "not an integer literal" and therefore poison. It now
  records `[:alias, NAME]` instead -- the bare name only, for exactly the
  reason this analysis is bare-name keyed at all: `(R1)::TILE` carries a
  scope register whose value is a runtime lookup this file does not
  model.

  `resolve_integral` then settles the resulting graph as a GREATEST
  fixpoint: start from every name with at least one definition, no
  unclassifiable definition and no out-of-bytecode poison, then
  repeatedly drop any name one of whose definitions aliases a name no
  longer in the set. Greatest rather than least is load-bearing, not a
  convenience. Bare-name keying cannot tell `Scene::Map::TILE` from
  `Game::TILE`, so `TILE = Game::TILE` reads as an alias to its OWN bare
  name, and a least fixpoint could never admit `TILE` at all even though
  `TILE = 16` (mruby-rpg2k/mrblib/game.rb:8) is right there. The same
  real self-alias shape occurs again in `Game::Battle`: `ROW_FRONT =
  Actor::ROW_FRONT` / `ROW_BACK = Actor::ROW_BACK` (game/battle.rb:36-37)
  against `ROW_FRONT = 0` / `ROW_BACK = 1` (game.rb:1574-1575).

  Soundness is a real induction on RUNTIME ASSIGNMENT ORDER, not on the
  shape of the graph -- which is what makes a greatest fixpoint safe here
  despite admitting cycles. Claim: for every admitted name N, every value
  ever bound to a constant with bare name N is a Fixnum. Walk the
  constant assignments a real run performs, in the order it performs
  them. The k-th assignment binding an admitted name N executes one of
  exactly two classified definitions: an integer literal (`LOADI*` only,
  a Fixnum by construction), or a read of a constant with bare name M
  that is also admitted -- and that read must SUCCEED, because reading a
  not-yet-assigned constant raises NameError and the program does not run
  at all, so some assignment binding M already happened strictly earlier
  and by the induction hypothesis stored a Fixnum. A degenerate cycle
  with no literal at its base (`A = B; B = A`) is admitted by the
  fixpoint and ruled out by exactly that NameError step: neither
  assignment can execute first, so no run reaches either. The induction
  needs every binding of an admitted name to be one this scan classified,
  which is precisely what the four pre-existing poison sources
  (`CLASS`/`MODULE`, `mrb_define_const*`, foreign Ruby sources,
  unclassifiable definitions) already guarantee -- a poisoned name can
  neither be admitted nor be the target of an admitted alias.

  Every one of the 24 newly-admitted names was checked against real
  source rather than counted, because a boolean or Float hiding behind an
  alias would be silently wrong (the proof emits a bare
  `mrb_fixnum_value(mrb_fixnum(a) - mrb_fixnum(b))` with no runtime check
  and no `mrb_funcall` fallback arm at all). `STATE_PERSISTS_ON_MAP =
  States::PERSISTS_ON_MAP` was the one worth real suspicion from its name
  alone, and `PERSISTS_ON_MAP = 1` (game.rb:9354) is a genuine integer
  flag; `RECOVER_CAP_2K = DAMAGE_CAP_2K` -> `999`, `RECOVER_CAP_2K3 =
  DAMAGE_CAP_2K3` -> `9999`, `SLOT_COUNT = RPG2k::MAX_SAVE_SLOTS` -> `15`,
  `RIGHT_X = ACTOR_WINDOW_W` -> `124`, `END_GAME_GAP = LINE_H` -> `16`.
  `Math::PI` stays correctly poisoned -- it is a Float, it appeared in
  the refusal tally 10 times as `::PI`, and nothing about this change
  makes it admissible.

  Also closes a real pre-existing soundness gap in the same walk, found
  while rewriting it. `literal_int_const_source?` had no label barrier at
  all, on the stated grounds that "a constant body is straight-line by
  construction" -- which is very nearly true but not true by
  construction. `X = cond ? "s" : 1` compiles to `JMPNOT` / `STRING` /
  `JMP` / `LOADI_1` / `SETCONST`, whose nearest backward writer of the
  source register really is a `LOADI` even though the other arm binds a
  String, so the name would have been admitted wrongly. `const_source_kind`
  now refuses to step across any address in `const_entry_addrs` -- the
  targets of exactly the five `JMP*` opcodes ops.h defines as moving `pc`
  within a frame, the same map `fixnum_proof_edge_sources` builds and
  verified the same way, plus every catch handler's raise target. This
  was measured, not assumed to be free: a build with the barrier in place
  and the aliasing arm disabled admits exactly the same 669 names and
  emits exactly the same 13993 call sites as the committed baseline, so
  it is pure soundness rather than a trade.

  Verification: `scripts/rpg2k_logic_check.rb` (1201), `scripts/
  rpg2k_scene_check.rb` (1062) and `scripts/lcf_testbed_check.rb` all
  still pass with identical counts. A real `g++ -std=c++17 -fsyntax-only`
  pass over the whole generated translation unit reports the same 17
  pre-existing, unrelated errors as the baseline does and zero new ones
  (12 `could not convert '1' from 'int' to 'mrb_value'`, 5
  `RPG2k::Scene::Map#vehicle_blocks` arity) -- diffed as error-text
  multisets between baseline and new output, not just compared by count.
  In `docs/bc2cpp_coverage.txt` the only lines that move are the constant
  count (669 -> 693), the call-site total (13993 -> 13870) and its
  non-POLY half (8085 -> 7962); compiled entry points (2258), method-level
  coverage (97.4%), the `#error` total (112), POLY-marked sites (5908),
  distinct dispatched names (1020) and the BLOCK_FALLBACK/LAMBDA_FALLBACK
  counts are all byte-identical. Per operator: `-` 567 -> 485, `/` 319 ->
  290, `*` 463 -> 455, `+` 681 -> 678, `==` 617 -> 616, summing to exactly
  123 with nothing else moving.

  Known, deliberately-unclaimed ground, measured rather than guessed.
  Arithmetic-defined constants are still poison and account for the whole
  remaining 36-site gap to the 159-site all-constants ceiling: `COLS =
  SCREEN_W / TILE + 1` and `ROWS = SCREEN_H / TILE + 1` (scene/map.rb),
  `VISIBLE_ROWS = (LIST_H - Window::BORDER * 2) / LINE_H`, `HEADER_H =
  LINE_H + Window::BORDER * 2`, `LIST_H = SCREEN_H - LIST_Y`. Chaining
  through those is deliberately NOT done here, because proving the TYPE
  is not enough: the emitted code calls `mrb_fixnum()` unchecked, so an
  Integer that is not a Fixnum would be a wrong answer, and
  Integer-times-Integer is not closed over Fixnum under `MRB_USE_BIGINT`.
  Doing it soundly means computing the exact values (every leaf is a
  `LOADI` literal, so this is possible) over the cross product of each
  bare name's whole value set and range-checking every result -- a real
  mechanism with its own semantics obligations, including mruby's own
  `Integer#/` rounding, for 36 sites. Declined at that ratio rather than
  approximated. The other previously-listed item, the `if/else` join case
  for dominance, remains open and now measures 173 sites at its ceiling
  (`dominance_LOADI` alone is 197 COSTLY refusals); it still needs all
  reaching definitions rather than the nearest one.
