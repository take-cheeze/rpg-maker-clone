# 0311. bc2cpp: TUPLE_RETURN_FACTS give `a, b = pair(x)` positional class sets

Date: 2026-10-02

## Status

Accepted

## Context

The goal was to cut the engine's guarded numeric operators (`+ - * / < <= > >=`) that still end in a
`bc2cpp_slow_*` helper, whose by-name tail runs for any operand class the helper does not own (ADR 0292).
NumericFlow (ADR 0276) removes that tail only when both operands are *proven* Integer/Float. In the wio closed
world, restricted to the engine owners (`RPG2k*`, `Game*`), master `2b317417` has **3,040** such helper calls (3,506
over the three compiled gems); each is a site whose operands NumericFlow could not prove.

### Where the unproven operands come from

`BC2CPP_NUMERIC_ROOTS=<file>` (`tools/bc2cpp/codegen_numeric_roots.rb`, a read-only probe: the generated code is
byte-identical with it on) writes, for each such site of the shipped pass, the class set of each operand and the
*leaves* it is computed from, looking through `+ - * /`, copies, `% -@ to_i to_f abs sin ...` and loop-carried
writers. Measured on `247a34e4` (the branch point; the shipped tree differs by 39 later commits), wio closed world,
engine owners, 2,384 operator sites with an unproven operand (the `<<`, `%`, `&`, `-@`
helpers are not covered by this arm):

| leaf family | sites it touches | sites where it is the only unproven leaf |
| --- | ---: | ---: |
| parameter (pooling refused or dropped by a caller) | 1,181 | 238 |
| result of a send (`hp`, `width`, `size`, `clamp`, `random`, ...) | 1,061 | 134 |
| instance variable | 702 | 206 |
| `GETIDX` on an unproven receiver | 377 | 17 |
| constant | 223 | 15 |
| `size`/`length`/`count` of an unproven receiver | 253 | 27 |
| **`AREF`** (destructuring `a, b = call`) | **256** | **9** |
| captured local | 123 | 16 |

A site usually has several leaves, so the table does not add up. The parameters that stay unproven are dropped by a
caller that passes one of these same leaves (a `Hash` element, an `AREF`, a native getter), not by the pooling rules
alone: 646 sites touch a parameter that pooling admitted and a caller dropped, and 140 of them have no other
unproven leaf.

To rank the roots honestly each one was also set to Integer *unsoundly* (a throw-away hack, not shipped) and the
probe rerun, which includes the cascade through pooled arguments and ivars. That is an upper bound, not a yield:

| root forced to Integer | unproven engine sites after (from 2,384) |
| --- | ---: |
| `GETIDX` results | 2,063 (-321) |
| `size`/`length`/`count` results | 2,244 (-140) |
| `hp max_hp mp max_mp width height x y` results | 2,275 (-109) |
| `min max clamp random rand param index span varied` results | 2,269 (-115) |
| `AREF` results | 2,293 (-91) |
| captured locals (`GETUPVAR`) | 2,346 (-38) |
| native-spelled ivars `@width @height @x @y @ox @oy @openness` (RGSS writes only Fixnums) | 2,354 (-30) |

No root is worth more than 13% even as an upper bound. The `GETIDX` and `size` roots are the largest but their sound
subsets are other ADRs' business (LCF rows 0294, element classes 0306/0312) or blocked by the name-level foreign
definitions (`size` is defined in core `mrblib` Ruby, so NUMERIC_RETURN_PROOF refuses it). `AREF` is the largest
root with a complete, local soundness argument: the Array a destructured call returns is a fresh literal.

## Decision

`tools/bc2cpp/codegen_tuple_returns.rb` adds one more fact family to the numeric fixpoint
(`compute_numeric_facts`): for a method name, the class set of **each position** of the Array it returns.

**Producer.** A name has a tuple fact when it is a numeric-return candidate (`numeric_return_candidates`: a call
reaches only the definitions the registry lists; no native, foreign, aliased or runtime-installed definition, no
`method_missing`) and every definition has this shape (`tuple_shape`):

- a bytecode body with no catch handler, no `RETNIL`/`RETSELF`/`RETTRUE`/`RETFALSE`/`BREAK`, and no `RETURN_BLK` in
  any nested block;
- every `RETURN` reads a register whose only reaching definitions are `ARRAY` instructions of one length
  (`BytecodeIR.reaching_definitions` without following moves), and from each `ARRAY` the control flow reaches that
  `RETURN` through `JMP`/`NOP` only (`tuple_walk_to_return`). Nothing reads, stores or changes the Array between its
  creation and its return, so it is fresh and held by nobody else;
- all definitions of the name agree on the length.

Position `j` holds the join, over every `ARRAY`, of what the numeric flow proved for register `a + j` before the
`ARRAY` (`ARRAY Ra n` builds the Array from `Ra..Ra+n-1`). Only numbers and nil survive; any other class becomes
`OTHER`, so a tuple can prove one position and not the next. Positions grow monotonically with the other pools
(`grow_tuple_returns`) and invalidate the destructuring methods' flows when they grow.

**Consumer.** NumericFlow gets an `AREF` transfer (`aref_mask`, an optional oracle method like `index_mask`). The
AREF reads a call's result register with nothing in between: the instructions back to the call are AREFs of the same
register (that write another register), the call is `SEND`/`SEND0`/`SSEND`/`SSEND0` of the tuple name, and every
instruction after the call up to the AREF has the previous instruction as its only predecessor
(`tuple_aref_call`, exception edges included). Nothing can change the Array first, and `OP_AREF` runs no Ruby
(vm.c). An index past the length reads nil, as `OP_AREF` does. Anything else is `OTHER`.

**Kill switch.** `BC2CPP_TUPLE_RETURNS=0` disables the family; the generated code is then byte-identical to master
(checked: `shipped.cxx` of the wio coverage pass).

### What this does not rely on

- No hint. Every fact is derived from the bytecode or it is `OTHER`; a violated fact could not change a branch, only
  reach `mrb_num_add`/`bc2cpp_num_cmp`, which raise on a non-number (memory-safe, the ADR 0276 argument).
- No `mrb_int` width: the facts are class sets. The check runs the fixture on a 32-bit `mrb_int` build and a build
  without mruby-bigint; the fixture spells its large value as the literal `1073741824`, no computed shift (AGENTS.md).
- `Marshal.load` of hostile data, which could build a closed-world object without `initialize`, is outside the model
  as for every fact here; it cannot make a method return a different literal.

## Consequences

Measured on the wio closed world (`scripts/bc2cpp_coverage_report.rb` shipped pass, `scripts/bc2cpp_dynamic_site_census.rb`
for the totals), base `2b317417`, engine owners (`RPG2k*`, `Game*`), mruby patch chain applied:

| | master | this change | delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_slow_*` helper calls in engine bodies | 3,040 | 2,999 | -41 |
| of which `add` / `div` / `mul` / `le` | 624 / 275 / 452 / 113 | 616 / 259 / 436 / 112 | -8 / -16 / -16 / -1 |
| `bc2cpp_send` in engine bodies | 2,199 | 2,199 | 0 |
| `bc2cpp_getidx` in engine bodies | 2,015 | 2,015 | 0 |
| all three gems: `NUMERIC_OPERAND_PROOF` arms | 379 | 420 | +41 |
| all three gems: slow-helper arms | 3,506 | 3,465 | -41 |

The 41 are **removals, not relocations**: each is a site whose helper call (with its by-name tail) became the core
body (`mrb_num_add`, `bc2cpp_num_div`, ...) with no by-name call. The `bc2cpp_send` count is unchanged because the
helper's tail was never a send at the site. 52 names get a tuple fact (`frame_ratio`, `half`, `dest_rect`,
`camera_position`, ...), but only **four methods change** (`Game::Transition#cross_split_ops` -20, `#horizontal_split_ops`
-10, `#vertical_split_ops` -10, `RPG2k::Scene::Map#update_screen_overlay` -1): the tuples whose elements the flow
already proves are `frame_ratio`, `half`, `shadow_origin`, `battle_cmd_window_rect`, `flash_color`; the other
consumers of those still have another unproven operand. The other tuples
(`dest_rect` and the 144 sites of `Window#draw_cursor_skin`, `cursor_start`, `camera_position`, `pan_offset`, ...)
keep `OTHER` positions because their *inputs* are not proven: a parameter (66 positions), the native-spelled
`@width`/`@height` (20), an Array element (18). That is why the realised 41 is under half of the 91 upper bound.

What would unlock more, in order: the native-written ivars (`@width @height @x @y @ox @oy`, whose RGSS writes are all
`mrb_fixnum_value`, audited like ADR 0302), parameters whose callers pass `Hash`/`AREF` elements, a literal
`a, b = [x, y]` destructure (11 sites; the element masks are not in the AREF's flow state).

### Checks

`scripts/bc2cpp_tuple_return_check.rb`: the AREF transfer and `tuple_shape` on hand-built bytecode (host only);
generated code of a closed-world fixture with positive cases (Integer, Float, Integer-or-Float, ternary tails, one
position unknown while another proves, a nil position narrowed by `||`, overflow past the fixnum range) and negative
worlds (a second definition with another length / a String / a non-literal, a name a native defines, a name core
`mrblib` defines, a stored-and-mutated Array, a block `return`, a rescue clause, an index past the length, a copy
mutated first, a branch join before the destructure, a reopened `Integer#+`, `method_missing`, the kill switch);
then compiled against interpreted on full-core, core-only, 32-bit `mrb_int` and no-bigint builds (values,
exceptions, and no dynamic dispatch in the proven methods). `scripts/bc2cpp_tuple_return_mutation_check.rb` breaks
ten soundness conditions in a copy of the generator, one at a time; each must fail a named check.

Not run here: the CI shards themselves (locally on 4 cores the check takes about 30 s per build set and the mutants
about 3 min);
PSP, Maix and Emscripten builds; the wio flash-size report; the optcarrot coverage check. The width builds are the
64-bit host with the targets' arithmetic defines, so 32-bit pointers are not exercised (ADR 0300).
