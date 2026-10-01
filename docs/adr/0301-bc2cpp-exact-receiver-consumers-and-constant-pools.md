# 0301. bc2cpp: the exact receiver proof reaches every arm wrapper; constants join the class pools

Date: 2026-10-01

## Status

Accepted

## Context

The request: remove more guarded by-name sends with proofs, not with relocations. (a) Carry the exact receiver
class (and Integer/Float facts) through register copies, return values and call arguments; (b) use literal and
fresh receivers for `max`, `min`, `to_f`, `abs` and the like; (c) give the `core_or_native` "kept" names an
exact receiver. ADR 0295 is the guard rail: a prototype that adds a domain (ranges, an argument-class pool of
its own) has to beat tens of sites, or it is not adopted.

Before building anything, the population was measured. `scripts/bc2cpp_dynamic_site_census.rb` on the wio
closed world (`scripts/bc2cpp_coverage_report.rb`, shipped pass, master `c7ff3846`) counts 3,294
`bc2cpp_send` sites in generated bodies. A temporary hook at the three places that build a by-name
fallback (the registered-expression chain, the POLY chain tail, `guarded_fallback_line`) printed, for each
site, the receiver's class set in the exact-class flow (ADR 0289, 0296) and the instruction that produced
the register. Findings (sites with a flow context, i.e. the final pass):

| population | sites | receiver already provably exact | receiver unknown |
| --- | ---: | ---: | ---: |
| registered-expression chains (`size`, `empty?`, `first`, `keys` ...) | 832 | 90 | 742 |
| `CLOSED_WORLD kept: core_or_native` | 157 | 13 | 144 |
| `[a, b].max` / `.min` on a literal Array | 62 | 62 (the Array) | elements: 1 all-Integer, 28 one unknown, 16 two unknown |

* **(a) is already carried.** `MOVE` is followed by the dominating-writer walk and by the flow itself, return
  values by the table of ADR 0289, arguments by the pools of ADR 0296 (only for a name with one definition and
  visible same-arity call sites, which is the condition ADR 0295 asked for). What was missing was a
  *consumer*: the 90 + 13 sites above had a proof and still built the guarded chain, because
  `exact_core_site` was set only around the last `native_direct_dynamic_line` of `compile_send`. The
  registered-expression chain (`compile_native_registered_expression`) and the tail of a POLY chain
  (`guarded_fallback_line`) never saw it.
* **The unknown 742 + 144 are unknown roots, not missed propagation.** Producer of the receiver register:
  a call result 245 (188 of whose own receiver is unknown), an ivar 160, an incoming argument 128, a
  `GETIDX` element 62 (ADR 0296 explains why element classes are not provable), a constant 44, a captured
  local 27, a literal joined with another value 21. Pool drops (`grow_class_pool`) are individually
  explainable: an ivar stored from a parameter, from `x.map { }` on an unknown receiver, from `false`, a
  join with an unmodelled path. No single missing rule moves more than a few dozen of them.
* **(b)** The literal Array of `[a, b].max` is exact and `compile_core_min_max` already has no further class
  test to drop; what keeps its by-name else is the *elements*, and 61 of 62 sites have an element the flow
  cannot call Integer or Float (`[value / 2, 1].max` with `value` an argument). `to_f` (20) and `abs` (17)
  receivers are `a - b` of unknown operands or unknown arguments; no literal receiver is among them. The
  RGSS-native Integer facts that would feed those operands are another change (ADR 0302).
* **(c)** 13 of the 157 `core_or_native` sites have an exact Array/Hash receiver (`delete` 8, `include?` 7
  counting the literal-Array ones, `shift`); the others are ivar, argument or call-result receivers.

## Decision

1. **One receiver proof for every arm wrapper of a send.** `compile_send` computes `exact_core_site` once,
   before the registered-expression branch, and sets it (`with_exact_core_site`) around
   `compile_native_primitive_send`, `compile_poly_small_n` / `compile_poly_table` (their fallback tails call
   `guarded_fallback_line`) and the final send. `compile_native_registered_expression` takes the site: an
   exact class with a registration of its own takes that arm with no tag test and no else
   (`CLOSED_WORLD_NATIVE_EXACT`); an exact class with none (`String#size`, which `NativeCoreDirect` supplies)
   drops the arms of the other classes and keeps only the fallback, which the site turns into the exact core
   body. The proof is unchanged (`exact_core_value_class`: a dominating literal or `*rest` write through
   `MOVE`; `exact_flow_core_class`: the flow of ADR 0289 with the pools of ADR 0296) and still needs
   `ClosedWorld#exact_instances_singleton_free?`. Nested compiles reset the site (`METHOD_COMPILE_STATE`).
2. **Constant class pools** (`CONSTANT_CLASS_POOL`, `codegen_class_pools.rb`). `NumericConstGroup` already
   knew which bare constant names have only visible definitions (`structural`: not poisoned by a class/module
   of that name, an outside native or foreign Ruby definition, or having no site). The exact-class run now
   gives each such name a pool, the join of the class sets its `SETCONST` sites store, with the same growth
   and drop rule as the ivar and argument pools (`grow_class_pool`; an unmodelled store or a pending
   exception drops the pool). `GETCONST`/`GETMCNST` read it (`ExactOracle#const_mask`), and an
   `INTEGER_CONSTANT_PROOF` name reads INT. The pools are off when the world can run a `const_missing`
   (any non-native definition, a dynamic installer), because that hook answers a failed lookup with a value
   no definition stores. `BC2CPP_CLASS_POOLS=0` turns them off with the others.
3. **`x.freeze` is `x`.** Most array/hash/string constants are `[...].freeze`, whose result was an unmodelled
   call. `return_class_send_mask` answers the receiver's own set for a `SEND0 :freeze` when
   `kernel_freeze_only?`: no Ruby definition, alias or installer of `freeze` reaches an instance
   (`ClosedWorld#instance_native_dispatch_safe?`: a definition owned by `X.singleton`, as `Graphics.freeze`
   is, answers only the class or module object, never an instance), every native registration of the name is
   `mrb_obj_freeze`, and `kernel.c`'s `mrb_obj_freeze` still ends in `return self;` (checked against the
   source on every run, like the `NativeCoreDirect` entries).

## What was not built

* **Element facts for `[a, b].max`.** Needs Integer facts for arguments and call results that are not
  provable today (62 sites, 1 with all-Integer elements). A guarded Integer loop with a *non-send* else
  (`mrb_num_cmp`) would remove the send but is a relocation into a helper, which this change does not count.
* **Native entries for `delete`, `include?` on an exact Array/Hash.** `Array#include?` is a Ruby override in
  `mruby-rgss` (`array_include.rb`), so an exact Array would need a guard-free direct call of that Ruby
  definition (the exact-target lookup refuses builtins, ADR 0295); `delete` has no audited entry. 15 sites.
* **Return classes of core natives on exact receivers** (`keys`, `map`, `select`, `to_h`, `dup` ...): at most
  17 of the 245 call-result roots have a receiver whose class set is exact; the other 188 have an unknown
  receiver, so the rule would not start a chain.
* **Attr readers in the return table.** Their result is an ivar pool, and the pools that matter
  (`@actors`, `@list`, `@commands`) are dropped for the stores above.

## Consequences

Measured on the wio closed world, shipped pass of `scripts/bc2cpp_coverage_report.rb`, same machine and
mruby, master `c7ff3846` against this branch:

| | before | after |
| --- | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 3,294 | 3,138 |
| `bc2cpp_send` held in helpers | 24 | 24 |
| calls into `bc2cpp_slow_*` / `bc2cpp_eqq` | 3,542 / 110 | 3,542 / 110 |
| calls into `bc2cpp_getidx` / `getidx0` / `setidx` | 2,417 | 2,397 |
| `mrb_funcall_with_block` + body `mrb_funcall*` | 476 | 476 |
| **sites that can reach by-name dispatch** (the sum, as `docs/bc2cpp-dynamic-site-census.md` counts them) | **9,839** | **9,663** |
| `bc2cpp_nomethod` sites (errors, not dispatch) | 4,435 | 4,399 |
| `shipped.cxx` bytes | 21,695,481 | 21,647,743 |

No helper is added and no call moves into one, so the 176 fewer sites are removals: 156 `bc2cpp_send`
and 20 `bc2cpp_getidx`-family callers (an exact constant Array/Hash takes `INDEX_EXACT`, which inlines the
fast path; 8 of its non-Fixnum-index elses are `bc2cpp_send "[]"`, counted above). That is 1.8% of the sites
that can reach a by-name call and 4.7% of the literal `bc2cpp_send` count; the text-count gain is the larger
number only because the other 9,500 are helper callers.

Per lever (`bc2cpp_send` in bodies; ablation on a scratch copy of the tree, three switches):

| lever | sites |
| --- | ---: |
| the site reaches registered chains, POLY tails and kept fallbacks | -116 (`size` 46, `empty?` 30, `[]` 13 net, `last` 11, `z=` 13, `x=` 7, `first` 6, `y=` 5, `keys` 4, ...) |
| constant pools (INT, Hash, String, unfrozen Array constants) | 0 |
| `freeze` answers its receiver (frozen constants become exact) | -40 |

Constant pools alone are worth nothing because the constants that matter are frozen; the two together hold
86 non-Integer constant pools (35 `Array`, 30 `Hash`, 3 `Integer`-or-`Hash`, 18 `String`) that the exact-class
flow did not have before.

The coverage report moves with it: 658 constant pools (86 non-Integer), ivar pools 171 to 176, argument
pools 58 to 76 (a constant now reaches a callee), `NILABLE_RECEIVER` sites 747 to 783, `INDEX_EXACT` arms
831 to 893, RETURN_CLASS_TABLE names 204 to 205; method coverage and `#error` counts are unchanged.

The remaining 3,138: unknown roots (above), RGSS native exact-class elses (517, the native Integer facts of
ADR 0302's neighbour), the `singleton_definer` names `width`/`height` (167; ADR 0302), `dynamic_install`
`update` (77).

## Withdrawal conditions

| condition | what withdraws | negative case |
| --- | --- | --- |
| singleton maker, `global_refusal` | every exact proof (ADR 0280) | `bc2cpp_exact_receiver_check.rb` |
| a class, module, outside native or outside Ruby definition of the constant name; a second class stored under the bare name; a store the flow cannot name | that constant's pool | `NEG ... LIST`, `MIXED` |
| `const_missing` defined or installed | every constant pool | `NEG a const_missing` |
| a Ruby `freeze` on instances, an alias or installer of `freeze`, a native `freeze` other than `mrb_obj_freeze`, a changed `mrb_obj_freeze` body | the `freeze` identity (frozen constants stay unknown) | `NEG a user freeze on instances`, runtime `box_freeze_val` |
| computed `const_set` | global refusal | `NEG a computed const_set` |
| `BC2CPP_CLASS_POOLS=0`, open world | constant pools; the site consumers stay (they need no pool) | kill switch, open-world cases |

## Residual risk

The arms are unchecked: a wrong exact class is a crash or a wrong answer, not a logged violation (ADR 0296's
residual list applies, and it adds one writer the scan cannot see: a constant defined from C by a helper that
takes the name as a literal outside the registration forms `scan_native` reads). The 32-bit case needs no
integer constant or mask (`scripts/bc2cpp_exact_receiver_flow_check.rb` ran on a `-DMRB_32BIT -DMRB_INT32`
build). Firmware smoke runs (psp, wio, maix) and CI were not run here.

## Tests

`scripts/bc2cpp_exact_receiver_flow_check.rb` (generated code: literal, register copy, return class and
argument pool reach `size`, `join` (a POLY chain), `str.size`, `Hash#size`; frozen Array/Hash/String
constants; every withdrawal above; behaviour on real mruby against the interpreter on a full-core and a
core-only build, FrozenError from a frozen constant, an overriding `freeze`, zero dynamic dispatches in the
exact methods), `scripts/bc2cpp_exact_receiver_flow_mutation_check.rb` (five mutants of the conditions
above, each must be killed), and the updated `scripts/bc2cpp_nested_compile_state_check.rb`
(`@class_const_pools`, `@kernel_freeze_only` are whole-program state) and
`scripts/bc2cpp_nomethod_reviewed_check.rb` (34 reviewed keys the branch removed because their fallback
became unreachable: the `x=`/`y=`/`z=`/`visible=` of exact native sprites; 36 added that the unmodified
master already produces, so its list was stale after ADR 0297's `no_target` arms: `Map#close_shop -> gold`,
`ItemMenu#refresh_target_cursor -> contents` and the like; I read the generated code of `close_shop`: the
`bc2cpp_nomethod` is the last else of a TYPED chain whose arms (`ShopState`, `MessageState`) are every
definer of `window`, i.e. the closed world's own proof, now with a reviewed key).
