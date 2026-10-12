# 0428. bc2cpp: options for proving constant-table indexes Integer (random and clamp)

Date: 2026-10-12

## Status

Proposed

## Context

Constant-table reads whose index is a method call are OTHER in bc2cpp's numeric
flow, because the index is not proven to be exactly the INT class. Two families
in `mruby-rpg2k/mrblib` are the motivating cases:

- `Character::CARDINALS[world.random(4)]` (`game.rb:6412` defines
  `CARDINALS = [2, 4, 6, 8].freeze`; the index reads are at `game.rb:6856`,
  `6887`, `7137`, `7184`, `7317`, `7320`).
- `WEATHER_PARTICLE_COUNTS[Game.clamp(w.strength || 0, 0, ...)]` (`scene/map.rb:1267`
  defines the table, `map.rb:1293-1294` reads it through the local `i`).

The frozen-table read gate is `codegen_frozen_tables.rb:92`:
`key_int = insn.op == 'GETIDX0' || state[key_reg] == NumericFlow::INT`. It is an
exact equality with the INT bit, so anything wider than INT (including NIL or OTHER)
reads as unknown, and the result of `CARDINALS[...]` becomes OTHER.

This ADR records what proof machinery already exists, which parts of it do not
reach these sites, and four options for extending it. No code is changed here.

### Verified claims (against origin/master 5b8f987)

1. **`random` has four definitions in the rpg2k tree, plus one in mruby-wolf.**
   - `Game::Rng#random(n)`: `game.rb:6353`, body `return 0 if n <= 0; next_int % n`.
     `next_int` is `game.rb:6348`: `@state = (@state * 75 + 74) % PERIOD`.
     `Rng#initialize` is `game.rb:6344` and sets `@state = (seed & 0xFFFF) + 1`.
   - `RPG2k::Interpreter::BattleRequest`: `interpreter.rb:262`, an
     `attr_accessor :random` (the zero-argument reader is one of the definitions).
   - `RPG2k::Scene::MapWorld#random(n)`: `scene/base.rb:535`, delegates to `@rng.random(n)`.
   - `RPG2k::Scene::VehicleWorld#random(n)`: `scene/base.rb:589`, same delegation.
   - `Wolf::Rng#random(n)`: `mruby-wolf/mrblib/interpreter.rb:1394`. It is not in
     the rpg2k closed-world conf (`mruby-rpg2k-compiled`), but `build_config.rb:505`
     adds `mruby-wolf` to the full build. Whether it enters the same registry is
     unverified; check the `== whole-program method registry ==` diagnostic
     (`bc2cpp.rb:355-358`).
   - The name is POLY (`registry.rb` keys every definition by name, and
     `bc2cpp.rb:356` prints `mono = defs.size == 1`). `numeric_return_candidates`
     admits a name only if every definition is a usable body
     (`codegen_numeric_returns.rb:45-63`). The attr_accessor reader returns a
     value that is not modelled as INT, so the name-wide join goes OTHER.
2. **`clamp` has two definitions.**
   - `Game.clamp(v, lo, hi)`: `game.rb:670`, singleton, returns `lo`, `hi` or `v`.
     The registry records it under the `Game.singleton` pseudo-owner
     (`registry.rb:256-261`), but under the bare name `clamp`.
   - `RPG2k::Scene::MapViewer#clamp(v, lo, hi)`: `scene/map_viewer.rb:403`, instance
     method, same body. Its bare call sites (`map_viewer.rb:266-337`) resolve through
     `self`, not through `Game`.
   - Both return a parameter, so the name-wide join is OTHER unless the arguments
     are proven. Nothing in the name-wide table records call-site arguments for a
     POLY name (see claim 5).
3. **`Comparable#clamp` from mruby-compar-ext is not in the build.** `build_config.rb`
   and `3rd/mgem-list` contain no `compar` entry. The `3rd/mruby` submodule is not
   checked out in this worktree, so the gem's own source was not inspected.
4. **The name-keyed numeric model.** `numeric_send_mask` (`codegen_numeric_returns.rb:251-287`)
   (`codegen_numeric_returns.rb:251-287`) takes `@numeric_return[name]` as its first
   lookup. It does not consult the receiver-scoped return-class flow. The grep for
   `return_class_` in `codegen_numeric*.rb` finds no call. The `SEND` result that feeds the index proof is
   therefore keyed by name in the numeric flow, not by receiver class.
5. **Call-site argument facts are MONO-only.**
   - `codegen_fixnum_proof.rb:741`: `next unless defs.size == 1 # rule 1`
     (`entry_arg_candidates`, `codegen_fixnum_proof.rb:735`; ENTRY_ARG_CALLSITE_PROOF admission).
   - `codegen_numeric_args.rb:1-10` (NUMERIC_ENTRY_ARG_PROOF) is the same admission
     with class sets. `codegen_numeric_proof.rb:269` emits the `NUMARG` diagnostic
     from `@entry_arg_numeric`, which only `setup_numeric_entry_args`
     (`codegen_numeric_args.rb:14-17`) fills.
   - The same single-definition rule appears at `annotations.rb:22` and
     `class_arg_types.rb:60`.
   - By-class enumeration exists for other purposes:
     `codegen_class_object_args.rb:113` (enumeration "without its single-definition
     rule") and `codegen_constructor_pools.rb` (ADR 0313).
6. **`numeric_send_on_number` models few operators.** `numeric_send_on_number`
   (`codegen_numeric_returns.rb:302-314`) handles zero-argument `to_i`, `to_int`,
   `floor`, `ceil`, `round`, `truncate` (INT), `to_f` (FLT), `abs`/`-@` (same bit), and
   one-argument `%` (through `NumericFlow.arith`) and `fdiv` (FLT). It returns OTHER
   for `&`, `|`, `^`, `<<` and `>>`. `NUMERIC_TO_INT_SENDS` is at line 243.
   `NumericFlow.arith` is `numeric_flow.rb:84-95`. The INT bit is `numeric_flow.rb:45`
   and means "Integer", not "fixnum" (ADR 0279).
7. **The exact-class (return-class) path cannot return the plain INT bit.**
   - `return_class_of_mask` (`codegen_return_classes.rb:725-728`) returns
     `RETURN_CORE_CLASS[mask] || return_class_name_of_bit(mask)`.
   - `RETURN_CORE_CLASS` (`codegen_return_classes.rb:16-17`) has Array, Hash, String
     and Range only.
   - `return_class_name_of_bit` (`codegen_return_classes.rb:147-149`) is
     `@numeric_class_bits&.key(bit)`. The INT bit `1` is never in
     `@numeric_class_bits` (those bits start at `CLASS_BIT_BASE`,
     `codegen_return_classes.rb:137-145`), so the result is nil.
   - Consequence: `return_class_scoped_send_mask` (line 470) and
     `return_class_union_send_mask` (line 537) both return nil for a pure INT result.
     An INT-result proof through the receiver-scoped path is not possible today.
8. **The receiver-scoped path is otherwise present.** `return_class_scoped_send_mask`
   (`codegen_return_classes.rb:470-510`) selects one body with
   `closed_world_exact_target` and computes a context-sensitive mask with
   `return_class_context_def_mask` (`codegen_return_classes.rb:594-623`), which binds
   the actual call arguments through `CallContextArguments.bind`. The union path
   needs 2 to 8 receiver class bits whose masks agree (`codegen_return_classes.rb:537-557`).
   The scoped path is consulted by `codegen_return_classes.rb:444`, which belongs to the
   exact-class flow, not to the numeric flow in claim 4.
9. **The `Rng` seed chain.** `Game::Rng.new(0x2000)` is called at `interpreter.rb:391`,
   `game/battle.rb:565` (`rng || Rng.new(0x2000)`) and `scene/map.rb:543`. The
   `Integer#&` in `Rng#initialize` (claim 1) is what makes `@state` OTHER today.

### Index sites in the shipped tree (estimate, grep-based)

Counted with `grep` over `mruby-rpg2k/mrblib` (rpg2k only, not wolf):

| Pattern | Sites | Where |
| --- | --- | --- |
| Constant table indexed by `random(...)` | 6 | `game.rb:6856, 6887, 7137, 7184, 7317, 7320` |
| Constant table indexed by `clamp(...)` (through a local) | 1 | `scene/map.rb:1293-1294` |
| Other constant table indexed by a call | 8 | `interpreter.rb:3002, 3026, 3578`; `game.rb:6684`; `scene/map.rb:232, 235, 239, 242` (the four `map.rb` sites index by `clamp_speed(s)`) |
| `random(` call lines, not in a constant index | 30 | e.g. `game/battle_support.rb:1304` (`rng.random(100) < e.drop_prob`) |
| `clamp(` call lines (`Game.clamp` 53, bare 9) | 62 | mostly arithmetic and ivar stores, not indexes |
| Integer bitwise or shift operators (`& ^ >> <<`) | about 35 | grep hits, a few false positives (e.g. `scene/map.rb:251-253`, `4160-4163`) |

The task brief listed four `CARDINALS` sites. The shipped tree has six. The two
extra sites are `MOVE_RANDOM` and `FACE_RANDOM` (`game.rb:7137`, `7184`).

The mruby-wolf tree has two more random-indexed reads: `mruby-wolf/mrblib/interpreter.rb:2542`
and `2562` (`DIRECTION_ORDER[@rng.random(DIRECTION_ORDER.size)]`). They are out of
scope for the rpg2k build.

The four `map.rb:232-242` sites index by `clamp_speed(s)`, a MONO method whose body
is `v = s.to_i; v < 0 ? 0 : v > 5 ? 5 : v`. Existing machinery (ENTRY_ARG proof plus
`to_i` in `NUMERIC_TO_INT_SENDS`) may already prove them, so they are not counted as
unlocked by any option below. They need their own measurement.

No run of the bc2cpp pipeline was done. `3rd/mruby` is not checked out in this
worktree, so the counts above are grep estimates, not measured.

## Decision

Proposed order and options are below. None is implemented by this ADR.

### Option 1: model `Integer#&`, `|`, `^`, `<<`, `>>` on INT operands

- **Change.** Add a rule to `numeric_send_on_number` (`codegen_numeric_returns.rb:302`)
  for argc 1 and names `& | ^ << >>`. Result INT when the receiver is INT-only and
  the argument is INT-only (NIL contributes nothing, because the call raises on nil,
  as `arith` does with `nil_raises`). Otherwise OTHER.
- **Exact semantics** (mruby `Integer` on infinite-precision two's complement):
  `&`, `|`, `^` of two values in a signed `w`-bit range stay in that range, so with
  fixnum operands they never leave `mrb_int`. `>>` is floor division by `2**n`.
  `x << n` is `x * 2**n` for `n >= 0`, and a negative `n` shifts right. `<<` can
  leave the `mrb_int` range, so its result is an Integer, not a fixnum.
- **Soundness condition.** An INT result for `&|^` requires both operands to be
  INT-only and to be fixnum-range values. `Float` has no `&` (NoMethodError), so a
  FLT bit in the receiver must produce OTHER (or a raise), not INT. For `<<`, the
  shift count must be proven in `0...(mrb_int width)` and the result is only an
  INT-class answer, never a fixnum (ADR 0279). Builtin-override safety must be
  checked with `builtin_class_send_safe?(name, ['Integer'])`
  (`codegen_numeric_returns.rb:292`).
- **32-bit caveat (AGENTS.md).** On the Emscripten, Wio and PSP builds `mrb_int` is
  32 bits. The result of `<<` can become a bignum there, and handing a bignum to a C
  function that needs `mrb_int` raises `RangeError`. The rule must never let an
  unbounded `<<` be treated as a fixnum. Any new constant spelled as a shift
  expression must use a literal instead (AGENTS.md, bignum-pool trap).
- **Consumers.** NUMERIC_RETURN (`grow_numeric_returns`, `codegen_numeric_returns.rb:220`),
  element index proof (`codegen_frozen_tables.rb:92`), NUMARG/NUMIVAR facts, and
  every `Rng` body (`game.rb:6340-6356`). Also the bitwise sites in `map.rb:229-253`
  and `4160-4163`, which change output (not just index proof).
- **Kill switch.** `BC2CPP_BITOP_RESULTS=0` (proposed name). With it set, the rule is
  absent and the output must match master.
- **Test.** New `scripts/bc2cpp/bitop_results_check.rb`: fixtures for each operator
  over INT, FLT, NIL, OTHER and bignum-literal operands, asserting the mask. Mutation:
  `bitop_results_mutation_check.rb` changes INT to FLT in one arm and must fail.
  Output test: `shipped.cxx` diff with the switch on and off (stderr diagnostics
  included), plus `bc2cpp-width` (32-bit `mrb_int`) for the shift arm.
- **Risk.** Output changes in every function that uses `& ^ >> <<` on an INT receiver
  (about 35 grep sites). Silent miscompile if `<<` is treated as a fixnum.
- **ADR.** An amendment to ADR 0276 (`NUMERIC_RETURN_PROOF`) is enough. It adds rules
  to an existing table and no new proof source.
- **Unlock.** Index sites unlocked by option 1 alone: 0 of the 7 `random`/`clamp`
  sites. Option 1 is a prerequisite for the `Rng` body (claim 9), so it is needed
  before option 4 can reach `Rng#random`.

### Option 2: call-site argument facts for POLY names, receiver-scoped

- **Change.** For a POLY name, enumerate call sites per receiver class: for each
  class `C` in the receiver flow, the sites that can select `C`'s body are the sites
  whose receiver can be `C`. Apply the ENTRY_ARG admission rules to those sites only
  (`codegen_fixnum_proof.rb:735`, `entry_arg_candidates`). This would let `NUMARG` facts exist for POLY
  names.
- **Why MONO-only today.** Rule 1 (`codegen_fixnum_proof.rb:741`) assumes every
  call site with that name reaches the one definition. For a POLY name, a site with
  receiver `X` reaches a body the enumeration does not know. The sites therefore do
  not bound that body's parameters.
- **Soundness condition.** Refuse unless every `SEND` of the name, `SENDB`, `SSEND`,
  `SUPER` and `to_enum` form (`call_site_index.rb:23-30`), is enumerated and its
  receiver class set is exact (`closed_world_exact_target` resolves one body per
  class). Refuse when any site has a computed name (`DynamicNames`, `dynamic_names.rb:7`),
  when a site's receiver is OTHER or unknown, when a subclass or module can reach the
  body (CHA), or when a foreign or native source defines the name
  (`@foreign_method_names`).
- **Consumers.** `numeric_entry_mask` (`codegen_numeric_args.rb:19`), NUMARG, and the
  contextual call arguments that `return_class_context_def_mask` binds.
- **Kill switch.** `BC2CPP_POLY_CALLSITE_ARGS=0` (proposed).
- **Test.** New `scripts/bc2cpp/poly_callsite_args_check.rb` with two classes sharing a
  name and different call-site argument classes. Mutation: drop the receiver-exactness
  test; the check must fail on the POLY body whose parameter sees the wrong class.
- **Risk.** Changes parameter types of every POLY method that gets a fact. The
  largest soundness surface of the four options.
- **ADR.** Yes, its own ADR. It adds a new proof source (admission for POLY names).
- **Unlock.** Alone, 0 index sites. The `random` argument `n` is already a literal
  at the six sites, and contextual binding (`return_class_context_def_mask`) gives
  the same fact per call. The `clamp` argument `v` is `w.strength || 0`, whose
  `strength` is an attr, so it stays OTHER. Option 2 is probably not needed for the
  `random` sites. It may be needed for `clamp`'s `v`.

### Option 3: resolve `Game.clamp` to its singleton body

- **Change.** When the receiver register is provably the constant `Game` (a `GETCONST`
  with a resolved lexical constant, ADR 0423), resolve the call to the
  `Game.singleton#clamp` body and key the result by that receiver, not by the bare
  name `clamp`. The name-wide join with `MapViewer#clamp` (claim 2) is not used for
  this site.
- **Soundness condition.** Refuse unless (a) the `Game` constant resolves lexically to
  the module at this site (no shadowing, no `const_missing`, `const_missing_free?`),
  (b) the singleton class of `Game` has exactly one `clamp` (`SDEF` at `game.rb:670`,
  no `extend`, no `define_singleton_method`), and (c) no `Game.clamp` redefinition
  exists in any `SCLASS` block (`closed_world.rb:983`). Refuse when the receiver
  scope is unknown: a receiver that is a parameter, `self` in a shared mixin, or any
  register not provably `Game`.
- **Consumers.** Exact-class scoped return (`return_class_scoped_send_mask`) once a
  singleton receiver bit exists, and the numeric flow if option 4 is in place.
- **Kill switch.** `BC2CPP_SINGLETON_CONST_RESOLUTION=0` (proposed).
- **Test.** New `scripts/bc2cpp/singleton_const_resolution_check.rb`. Fixtures: a
  `Game.clamp` site, a bare `clamp` inside `MapViewer` (must stay on `MapViewer#clamp`),
  a shadowed `Game`, and a `Game.singleton` reopen. Mutation: resolve bare `clamp`
  to the singleton body; the check must fail.
- **Risk.** Changes name resolution of singleton methods. Affects every `Owner.name`
  call on a constant receiver, not only `clamp`. The registry label
  `Owner.singleton` (`registry.rb:186, 213`) is part of the same mechanism.
- **ADR.** Yes, its own ADR. It changes how an SDEF is keyed.
- **Unlock.** Alone, 0 index sites: `v` and `lo`/`hi` still need arguments. With
  option 4 and contextual binding, at most 1 site (`map.rb:1293-1294`).

### Option 4: an INT-result return proof, scoped per receiver

- **Change.** Allow `return_class_of_mask` (claim 7) to return a class name for the
  plain INT bit (as `Integer`), and let `return_class_scoped_send_mask` and
  `return_class_union_send_mask` return an INT mask. Thread that answer into
  `numeric_send_mask` (claim 4), which today reads only the name-keyed table. The
  receiver's exact class set selects each body (claim 8). Every `RETURN` of a
  definition must be provably INT, and context binding (`return_class_context_def_mask`)
  supplies the call arguments.
- **Refusals.** Refuse when any return site is OTHER, NIL or a `RETURN_BLK`/`BREAK`
  whose value is not INT. Refuse when the receiver class set is not exact, when an
  INT-bit receiver has no body on one arm of a union, when a recursion key is active
  (`@rc_scoped_return_active`), and when a captured local is written
  (`return_class_context_upvar_mask`). Refuse when the INT result would be used as a
  fixnum without the range argument of option 1 (INT means Integer, ADR 0279).
- **Consumers.** Element index proof (`codegen_frozen_tables.rb:92`), NUMERIC_RETURN,
  and the frozen-table read result (`CARDINALS[...]` becomes the slot class, not OTHER).
- **Kill switch.** `BC2CPP_INT_RETURN_SCOPED=0` (proposed). It reuses the existing
  `BC2CPP_SCOPED_ACCESSOR_RETURNS` / `BC2CPP_USER_RECEIVER_UNIONS` family of switches
  (`codegen_return_classes.rb:538`, `codegen_return_classes.rb:454`).
- **Test.** New `scripts/bc2cpp/int_return_scoped_check.rb` with fixtures per
  refusal. Mutation: make one return site OTHER-tolerant; the check must fail. Output
  test: `shipped.cxx` diff with the switch on and off, and the `NUMRET` diagnostic
  before and after.
- **Risk.** Changes the element type of every frozen-table read whose index is a
  scoped call. It touches the exact-class and numeric flows together, which is the
  largest coupling of the four.
- **ADR.** Yes, its own ADR. It is an architectural change (a new integration
  between two flows, AGENTS.md).
- **Unlock.** The six `random` sites in `game.rb`, but only with option 1 (for the
  `Rng` body `next_int % n` and `@state`). The `clamp` site needs option 3 as well.
  The estimate is up to 7 of 15 rpg2k constant-table call-indexed sites, and 0 of
  them with option 4 alone (the `Rng` seed chain needs option 1).

## Recommended order

1. **Option 1 (bit operators).** It is the smallest and the most measurable: a
   fixture-driven rule table plus a `shipped.cxx` diff. It is a prerequisite for the
   `Rng` body in option 4. Its alone-unlock is 0, so it is only worth shipping with a
   measured output diff. The 32-bit `<<` rule must be settled first.
2. **Option 3 (`Game.clamp` resolution).** It is a narrow, lexically decidable change
   that removes a false POLY join. It unlocks at most one site. It needs its own ADR,
   so this is the first decision after option 1.
3. **Option 4 (scoped INT return).** It is the only option that unlocks the six
   `random` sites. It depends on option 1, and it is the largest coupling. Its ADR
   should be written once options 1 and 3 have measured output.
4. **Option 2 (POLY call-site args), last or not at all.** Contextual binding (option 4)
   already supplies the `random` argument per call. Option 2 is only needed if
   measurement shows `clamp`'s `v` is still OTHER after option 3. It carries the
   largest soundness surface, so it should not be started until the measurement
   says it is needed.

Before any option starts, run the bc2cpp registry diagnostic and the `NUMARG`/`NUMRET`
lines on master to confirm the POLY status of `random` and `clamp`, and whether the
`mruby-wolf` `Rng#random` is in the same registry (claim 1).

## Consequences

- No code changes. The claims above were verified by reading the cited lines on
  origin/master 5b8f987. The site counts are grep estimates. A measured count needs
  `3rd/mruby` checked out and a bc2cpp run.
- ADR numbers 0426 and 0427 are not present on master. This ADR uses 0428 as the
  branch was assigned.
- Option 1 is the only option whose output change is broad (about 35 bitwise sites).
  Options 2 and 4 are the only ones that widen what the numeric flow believes about
  parameters and returns. Their refusals are the soundness argument and must be
  tested before enabling.
- The four options each have a kill switch, so each can be turned off to restore
  master output while its check and mutation check run.
