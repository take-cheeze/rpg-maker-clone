# 0307. bc2cpp: a receiver the class flow proves is one RGSS native class calls the wrapper body without its class test

Date: 2026-10-02

## Status

Accepted

## Context

The request: remove by-name `bc2cpp_send` sites from the compiled rpg2k gem, starting with the census category
`rgss_native_exact_class_else` (calls like `draw_text`, `fill_rect`, `blt`, `clear`, `bitmap=`, `opacity=` on
RGSS `Bitmap`/`Sprite`/`Window`/`Viewport` receivers held in ivars, arguments or call results), with a
proof, not a relocation. ADR 0210 (hints are not proofs) and ADR 0290 (a violated proof is an error) apply.

Measured first (`scripts/bc2cpp_coverage_report.rb`, `scripts/bc2cpp_dynamic_site_census.rb`, wio closed world,
master `247a34e4`; re-measured unchanged on `359b9abd`), then each site's receiver by a temporary hook in `compile_send`
(not committed) that printed the class set of the exact-class flow, the producer of the receiver register and, for
an `@ivar`, the pool state. The 463 rpg2k sites (`RPG2k_*`/`Game_*` functions) group by root cause as:

| root cause | sites | what it is |
| --- | ---: | --- |
| `Bitmap.new(w, h)` argument tags | 120 | the constructor arm tests `mrb_integer_p` of both arguments and dispatches otherwise (`Bitmap.new("file")`); the receiver is the stable constant, so this is an *argument* proof (Fixnum), not a receiver proof |
| flow proves one class, nil-or-one class | 164 | the receiver is already `RGSS::Bitmap`/`RGSS::Sprite`/... in the exact-class flow (ADR 0289/0296: 74 exactly one class, 90 nil plus one class), yet the site kept its guard and its by-name else |
| receiver class not provable | 174 | call result 41 (`x=`/`y=` on `Game::Character` results), ivar whose pool is dropped or structural 49, captured local 33, incoming argument 21, `GETIDX` element 21, a register written with `nil` 9 |
| `Hash#clear` (not an RGSS site) | 2 | |
| no diagnostic row | 3 | |

The 164 are the finding. They are not an unproven class: `compile_send` has two families for an RGSS receiver. The
older arms (`fill_rect`, `blt`, `stretch_blt`, `draw_text`, `copy_blt`, `text_size`, `bitmap=`, `opacity=`,
`tone=`, `openness=`, and the zero-argument `clear`/`width`/`update`/`dispose` wrappers) test
`mrb_obj_class(M, recv) == rgss::native_X_class()` and keep the send as their else, because the class there is a
`trace_new_target` hint (whole-program facts, not proofs). NATIVE_EXACT_DIRECT (ADR 0281) is the unguarded consumer
of the flow's proof, but it only covers names with an entry in `NativeDirect::ENTRIES` and it requires the name to
be spelled only by the RGSS sources, so `clear` (also `Hash#clear`) and `fill_rect`/`blt`/`draw_text` (no entry at
all) never reached it, and the hint arm ran first for the rest. A receiver the flow proves exact therefore still
paid a compare and kept a send.

## Decision

`tools/bc2cpp/codegen_exact_native_wrappers.rb` adds EXACT_NATIVE_WRAPPER, tried in `compile_send` ahead of the
guarded arms:

- The proof is the existing one, unchanged: `exact_flow_user_class` (ADR 0289, class pools ADR 0296, constant pools
  ADR 0301), which needs `ClosedWorld#exact_instances_singleton_free?` and, inside a NILABLE_RECEIVER non-nil arm,
  the nil bit of that one register removed. No pool, domain or argument pool is added (ADR 0295 is untouched).
- When it names one RGSS native class that has a wrapper body for this name and arity, the site is
  `r = rgss::<body>(M, recv, args...)`: no class test, no else. The body, argument layout and class set are the
  guarded arms' own (`CALLS`, `NATIVE_WRAPPER_ZERO_ARG_DIRECT`, `dispose`), and `native_wrapper_owner_safe?`
  (registry has a native registration and no Ruby definition on the owner, no prepend) plus
  `symbol_installed_names` and `devirt_blocked_name?` must hold, which is what the guarded arm already needed. The
  runtime test it replaces is the exact class the flow proved, so the call is the arm's call with a constant guard.
- A wrong arity, a receiver the flow cannot prove, `call_receiver`/`call_arguments` substitution (inlined loops: the
  proof reads the original SEND's registers) and a block call keep the old code.
- `NILABLE_RECEIVER` (ADR 0296) already tests nil once and compiles the non-nil arm with the exact receiver; its
  worth test now counts `EXACT_NATIVE_WRAPPER` among the unguarded marks (`EXACT_MARK`), because without it a site
  whose plain code had already lost its dispatch (a proven-dead nomethod tail, `width`/`height`) fell back to the
  plain chain and a new NOMETHOD key appeared.
- Kill switch: `BC2CPP_EXACT_NATIVE_WRAPPERS=0` restores the guarded arms for every site.

The call is *unchecked*, like ADR 0281's NATIVE_EXACT_DIRECT and ADR 0296's native exact consumers: a wrong class
would reach the wrapper with the wrong `DATA_PTR`. I kept the pool risk of ADR 0296 rather than adding a guard whose
else is an ADR 0290 violation line: the proof is the pool proof, and a cheap compare per drawing call is what the
change removes. `BC2CPP_CLASS_POOLS=strict` remains the conservative setting.

### What was not built

- **The 120 `Bitmap.new(w, h)` sites.** The receiver is the stable constant already; the else is the String form.
  Dropping it needs both arguments proven Fixnum (`proven_fixnum_operand?`, as `native_exact_direct_code` does with
  `int_proven`), an argument-domain proof with a different yield (the literals `Bitmap.new(4, 4)` are proven, the
  `[w, 1].max` arguments are not). It is a separate change.
- **The 174 unprovable receivers.** Producers are call results (41), ivars whose pool is dropped (`@state` stored
  from parameters) or structural (`@contents` spelled by a native source) (49), captured locals (33), arguments
  with no visible caller (21), `GETIDX` elements (21; ADR 0296 explains why element classes are not provable) and
  a register written with `nil` (9). No single rule moves more than a few dozen.
- **The 12 sites the flow still proves exact or nil-or-one-class** after this change: 8 `x=`/`y=` (their
  NATIVE_DIRECT entry takes an `mrb_int` and tests the argument tag, which only an Integer fact removes; inferred
  from the arm, not traced per site), 3 `draw_text` on nil-or-Bitmap and 1 other.

## Consequences

Measured on the wio closed world (same machine and mruby, merged master `359b9abd`, kill switch against default,
shipped pass of the report, so the only difference is this change):

| | before | after | delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 3,030 | 2,851 | -179 |
| of them in `RPG2k_*`/`Game_*` functions | 2,205 | 2,047 | -158 |
| of them in `RGSS_*` functions | 273 | 252 | -21 |
| `rgss_native_exact_class_else`, rpg2k only (463 listed above) | 463 | 305 | -158 |
| `rgss_native_exact_class_else`, all gems | 516 | 337 | -179 |
| `bc2cpp_send` held in helpers, calls into `bc2cpp_slow_*`, `getidx`, `eqq` | unchanged | unchanged | 0 |
| `EXACT_NATIVE_WRAPPER` calls | 0 | 257 | +257 |
| `NILABLE_RECEIVER` sites / `bc2cpp_nil_receiver` calls | 787 | 868 | +81 |
| `bc2cpp_nomethod` sites (errors, not dispatch) | 4,409 | 4,365 | -44 |
| `shipped.cxx` bytes | 21,706,322 | 21,562,977 | -143,345 |

Removal versus relocation, honestly: 98 of the 179 sends are plain removals (an exact receiver, no helper). 81 are
sites whose receiver is nil-or-one-class: the send went away but the site gained a nil test whose nil arm is
`bc2cpp_nil_receiver`, the cold helper of ADR 0296 that dispatches only to let mruby raise its own `NoMethodError`
for nil. Counting that helper call as a by-name-capable site, the net on "sites that can reach by-name dispatch" is
-98, not -179. The other 78 `EXACT_NATIVE_WRAPPER` sites had no send (a class test with a `bc2cpp_nomethod` else)
and lost the class test; they account for the 44 fewer nomethod sites together with eight reviewed fallbacks
(`dispose`) that became unreachable. `NOMETHOD_REVIEWED` lost those eight keys and gained none
(`scripts/bc2cpp_nomethod_reviewed_update.rb`).

A first version that left `EXACT_NATIVE_WRAPPER` out of NILABLE_RECEIVER's exact marks added two NOMETHOD keys
(`DebugMenu#refresh_editor -> width`, `Map#draw_parallax -> height`) and extra sites of a third: the nil test was
not worth it once the plain code had a dead-nomethod tail, so the nilable form was dropped for a class chain. They
went away with the mark, which is why the mark has a test of its own.

## Withdrawal conditions

| condition | what withdraws | negative case in `bc2cpp_exact_native_wrappers_check.rb` |
| --- | --- | --- |
| a parameter, a second class (a subclass instance included) or an `attr_writer` stored in the ivar | its pool, so the guard | `put_bmp`, `sub`, `read_param`, `read_written`, `read_mixed` |
| `instance_variable_set` (literal or computed name), a native source spelling the ivar, `define_method` writing it, a singleton maker, `Marshal` under `=strict` | pool (ADR 0296) | the matching variants |
| a Ruby definition, `define_method` or prepend of the wrapper name on the owner | `native_wrapper_owner_safe?`, `symbol_installed_names` | `class RGSS::Bitmap; def clear` and `define_method(:fill_rect)` variants |
| an arity the wrapper does not take, a block call, a substituted receiver | the hook declines | `bad_arity` |
| `allocate` (an unassigned instance) | exactness: nil joins the set, NILABLE_RECEIVER takes it | `an allocate` variant |
| `BC2CPP_EXACT_NATIVE_WRAPPERS=0`, `BC2CPP_CLASS_POOLS=0`, the open world | the consumer or its proof | kill-switch and open-world cases |

The substituted-receiver condition (`call_receiver`/`call_arguments`, inlined loops) has no mutant: no fixture
shape was found whose traced register is exact while the substituted receiver is not, so that line is by analogy
with the other flow consumers, not tested.

## Residual risk

ADR 0296's list applies unchanged: an unseen writer (hostile `Marshal.load` bytes, a native that builds the ivar
name at run time) turns the unguarded call into a crash. The wrapper bodies are the real RGSS ones in the game
build; the behavioural check runs the compiled call against the interpreter with *stand-in* `rgss::` bodies
(the real ones need SDL), so it proves the plumbing (argument layout, the `opacity_given` flags, nil handling,
dispatch counts), not the bodies. The game smoke (`rpg2k_boot_check.bash`), the firmware smokes (psp, wio, maix)
and the CI shards were not run where this was written.

## Tests

`scripts/bc2cpp_exact_native_wrappers_check.rb` (generated code for every wrapper and arity, equality of the
unguarded call with the guarded arm's call, every withdrawal above, kill switches, `Marshal` strict, open world;
behaviour on real mruby with stand-in bodies: compiled against interpreted answers and recorded calls, nil
receivers, zero dispatches on the exact methods, on full-core, core-only and 32-bit `mrb_int` builds),
`scripts/bc2cpp_exact_native_wrappers_mutation_check.rb` (eight mutants, each killed), the `native-wrappers` shard
of `bc2cpp-checks`, and the updated `NOMETHOD_REVIEWED` list. `scripts/bc2cpp_fixture_runtime.rb` gained
`-I include` so a fixture can include `rgss_construct.hxx`.
