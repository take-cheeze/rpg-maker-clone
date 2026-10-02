# 0309. bc2cpp: attr_reader result classes, exact core arms, and where the rpg2k call-result receivers come from

Date: 2026-10-02

## Status

Accepted

## Context

The request: raise direct-call coverage of the compiled rpg2k gem for the sites whose receiver is a call
result, or whose by-name tail is `closed_world_kept:core_or_native`, `singleton_definer`,
`other:no_guard_nearby` or `poly_diag:*receiver_class_unresolved`, find which method's return value is the
receiver and why its class is unproven, and implement the single highest-yield sound slice.

The census (`docs/bc2cpp-dynamic-site-census.md`) attributes a site to a receiver origin with a text
heuristic over the register's last assignment, which says `register_copy` for a third of them and
`direct_call_result` for sites whose receiver is an `iv_get`. It cannot say which method produced the
value. So the first change is a measurement tool, and the numbers below come from it.

### Measurement: `BC2CPP_SEND_ROOT_REPORT`

`tools/bc2cpp/send_root_report.rb` (a diagnostic, off unless the variable is set) hooks `compile_send`. For
every send whose generated code still holds a by-name call it records the nearest producer of the receiver
(`send`, `ivar`, `incoming_arg`, `index`, `getconst`, `array`, `upvar`, ...), for a call result the name
and why that name has no class (`candidate_dropped:<definitions whose result is unmodelled>`,
`foreign_spelling`, `not_fully_visible`, `aliased`, `no_definition`, `unusable_def`), for an ivar the state of
its class pool (`pooled`, or `failed`/`structural:<cause>` with the stores the flow cannot name), and the
class set the exact-class flow proves for the receiver. It also writes a `/*SR:<irep>:<site>*/` tag on
every by-name line of the C++ so `scripts/bc2cpp_send_root_report.rb` can join a *shipped* site (the
census's `--tsv`) to its row. Without the tag join the first version of the report counted 7,254 rpg2k
"sites" against the census's 2,182: it counted every compile of a guarded arm whose comment names a
`mrb_funcall` fallback, and arms that are later replaced. With it, 1,994 of the
2,196 shipped rpg2k sites are attributed; the rest come from emitters that do not go through
`compile_send` (inlined loop bodies).

Measured on the wio closed world at master `2b317417` with both features below off (3rd/* submodules present;
with them empty the census reports about 8,000 sends and the nomethod list differs):

| producer of the receiver | sites |
| --- | ---: |
| a call result | 504 |
| an ivar | 503 |
| an incoming argument | 303 |
| a `GETIDX` element | 203 |
| a constant (`Bitmap.new`, `Sprite.new` and the like) | 166 |
| an Array literal | 107 |
| a captured local | 81 |
| not attributed (loop bodies) | 202 |
| the rest | 127 |

The producers of the 504 call results:

| root | sites |
| --- | ---: |
| `Bitmap.new`/`Sprite.new` results: the class is known, the consumer is an RGSS wrapper (ADR 0307) | 69 |
| a project getter whose slot has no class pool (`actors`, `teleport_targets`, `vehicle`, `skills`, `items`, `char`, `level`, ... 60 names) | about 150 |
| a name spelled by foreign Ruby or a native whose result depends on the receiver (`map`, `to_s`, `keys`, `reject`, `name`, `to_h`, `parameters`, `now`) | about 110 |
| `contents` (an alias of an ivar reader) | 20 |
| tracked, the consumer is the limit | 30 |
| the rest | about 115 |

Why the ivars have no class pool (503 ivar-rooted sites): 205 are pooled (the receiver class is known and the
consumer goes by name for another reason, mostly RGSS wrappers), 225 are dropped because a store is
unmodelled, 57 are structurally refused (a native or foreign source spells the name, or reflection), 8 by an
`attr_writer`, 8 are open. Of the 225 dropped, the first blocker is a **constructor argument** (`@state = state`
in `initialize`, 99 sites; `Scene::Map#@state` alone is 21) or a core-method result on a receiver of
unknown class (`select`, `uniq`, `dup`, `map`, `clamp`, about 60), and then booleans (the flow has no bit
for `true`/`false`).

The ranking is flat. No single cause explains more than about 5% of the 2,196 sites, and the largest
(constructor arguments, which ADR 0295/0296 leave out because `initialize` is excluded from argument
pools) is a new proof of its own (every `new` site, `super`, and `self.new` in a class method must be
visible), not a return-class rule. It is the most valuable remaining lever and is not built here.

## Decision

### 1. ACCESSOR_RETURN_CLASS: an `attr_reader` returns its slot's class set

RETURN_CLASS_TABLE (ADR 0289) joined every definition of a name and dropped the name when one was
unmodelled. An `attr_reader` has no irep, so `return_class_def_mask` answered OTHER for it, and every name
that any `attr_reader` defines (`party`, `db`, `font`, `screen`, `message_config`, `switches`, ...) was
dropped whatever the class pools proved about the slot.

`tools/bc2cpp/codegen_return_accessors.rb`: a getter definition (`d.irep.nil?`, kind `:ivar_accessor`, not a
writer, not on a singleton or a `<native>` owner) returns the class pool of the slot it reads, the pool
`GETIV` in a method of that class family reads (`numeric_family(d.owner)`, name), plus nil unless every
constructor assigns the slot before `self` escapes (`numeric_ivar_assured?`). No pool (structural: a writer,
reflection, a foreign spelling) is OTHER. The name then joins the table like any other: every definition
of the name must be modelled, so a second class with a reader of the same name, a Ruby override or a
`define_method` ends it.

Consumers are the existing ones: the exact-class flow (`exact_flow_class`, `NILABLE_RECEIVER`,
`receiver_instances`), through `return_class_send_mask`. Kill switch `BC2CPP_RETURN_ACCESSORS=0`.

### 2. EXACT_CORE_ARMS: two older arms take the proof NATIVE_CORE_DIRECT already trusts

`exact_core_value_class` proves a receiver is exactly Array, Hash, String or Range (a literal, a copy, the
flow). NATIVE_CORE_DIRECT (ADR 0257) and the registered-expression arms (ADR 0301) use it. Two arms did not:

- `ARRAY_PUSH` (`push`, `<<` on an exact base Array) kept `mrb_array_p(r) && class == array_class` and a
  by-name else, and for `<<` the Integer shift arm behind it (a call into `bc2cpp_slow_lshift`). With the
  proof the site is `mrb_ary_push(M, r, v)` and nothing else (`exact_array_push_code`).
- the `TYPED` call of a core class's own compiled body (`a.cr_has?(x)` with a receiver traced to Array,
  guard `array_class`) takes the `EXACT_TYPED` form when the flow proves the same class the guard names
  (`exact_core_typed`, the trace and the flow must agree).

Both need `builtin_class_send_safe?` or the registry candidate they already needed, and
`exact_instances_singleton_free?` through `exact_core_value_class`. A frozen exact Array still reaches
`mrb_ary_push`, which raises FrozenError as the method does. Kill switch `BC2CPP_EXACT_CORE_ARMS=0`.

## Withdrawal conditions

| condition | what withdraws | negative case |
| --- | --- | --- |
| `attr_writer`/`attr_accessor` for the slot | its pool, so the reader (`the writer's value joins the reader's result`) | `a writer on the ivar`, `held_tag`, `held2_tag` |
| a second class with a reader of the name, a subclass override, a `define_method` or an `alias_method` of the name | the name's table entry | the four worlds of that name |
| a store of another class, in the class or in a subclass | the pool is two classes | `a store of a second class`, `a store from a subclass` |
| `instance_variable_set` of the ivar | the pool (structural) | `an instance_variable_set of the ivar` |
| a slot no constructor assigns | the nil bit joins, so no plain exact call | `an unassigned slot` (and a mutant) |
| a nil store | `NILABLE_RECEIVER`, one nil test | `a nil store` |
| a Ruby `Array#push`/`Array#<<` | the native arm of that name | `a Ruby Array#push`, `#<<` |
| a singleton maker (`def obj.x`, `singleton_class`, ...), the open world | every flow proof (`exact_instances_singleton_free?`) | `a def on an object`, `open world` |
| a subclass of Array, a Hash, an unknown or mixed receiver | the Array arms | `push_sub`, `push_hash`, `push_param`, `push_mixed`, `typed_has_param`, `typed_has_mixed` |
| `BC2CPP_RETURN_ACCESSORS=0`, `BC2CPP_EXACT_CORE_ARMS=0`, `BC2CPP_CLASS_POOLS=0` | each feature | the three kill-switch checks; with both switches off the shipped C++ is byte-identical to master |

## Consequences

Measured as above, wio closed world, master `93c4de03` (ADR 0306-0308 and 0310 merged), kill switches against
defaults on the same tree (the switches off give a C++ byte-identical to master's; 3rd/* submodules present):

| | before | after | change |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` sites, all gems | 2,815 | 2,745 | -70 |
| `bc2cpp_send` sites, rpg2k (`RPG2k*`, `Game*`) | 2,012 | 1,949 | -63 |
| rpg2k sites in the census | 2,009 | 1,946 | -63 |
| calls into `bc2cpp_getidx`/`getidx0`/`setidx`, rpg2k | 2,209 | 2,163 | -46 |
| calls into `bc2cpp_slow_*`, rpg2k | 2,999 | 2,853 | -146 |
| `bc2cpp_nomethod` sites, rpg2k | 4,257 | 4,209 | -48 |
| **sites that can reach by-name dispatch, rpg2k** | **7,605** | **7,349** | **-256 (-3.4%)** |
| the same, all gems | 9,137 | 8,864 | -273 |

By feature: ACCESSOR_RETURN_CLASS alone is 14 sends, 46 index-helper calls and 48 nomethod sites (reach
-61); EXACT_CORE_ARMS alone is 49 sends and 146 `slow_lshift` calls (reach -195). Most of the second is
ADR 0308's captured-local classes reaching `ARRAY_PUSH`: a block's `acc << x` on an Array captured from the
method now has the proof, which is the follow-up that ADR measured and left out. **All of it is removal**:
no helper gained a caller. Across all gems `bc2cpp_slow_lshift` callers went 282 to 126, `bc2cpp_getidx`
2,095 to 2,059 and `bc2cpp_setidx` 219 to 209 (receivers that became `INDEX_EXACT`), the census's
`ARRAY_PUSH` sites 96 to 51 and `TYPED` sites 48 to 35. In the rpg2k census categories
`core_tag_chain_else` went 908 to 860 (704 to 670 and 204 to 190), `core_or_native` 255 to 239 and
`singleton_definer` 101 to 100; `receiver_class_unresolved` rose by 2 as sites changed category. 36
`NOMETHOD_REVIEWED` keys went with their fallbacks (regenerated with
`scripts/bc2cpp_nomethod_reviewed_update.rb`, removals only, none added).

That is small, and it should not be oversold. Of the categories the request names, `core_or_native` moved by
16, `singleton_definer` by 1 and `other:no_guard_nearby` by 0; the 330 sites it counted under a call-result
origin are mostly the other roots of the tables above, and the accessor rule removed 14 sends.

### What was measured and not built

- **Constructor argument pools** (the largest root, 99 ivar sites plus the 17 `initialize` argument sites):
  needs every `new` site (including 58 computed ones in the engine and `self.new` in class methods), every
  `super`, and `allocate`/`send`/native construction visible, per class. Not a return-class rule; left.
- **A name's definitions scoped to a singleton** (`class << Graphics; alias_method :update, ...` in the RGSS
  probe makes `update` a global dynamic install, 76 `update` sites): implemented and measured. It moved 42
  rpg2k sites from `dynamic_install` to `core_or_native` and removed none, because the next gate
  (`@outside_names` for the RGSS natives, no exact path in front of the RGSS wrapper arms for a project
  subclass of a native) still refuses. Reverted, not shipped.
- **`attr_writer` pools**: 8 ivar sites. Not worth a change to the group structure.
- **Core method results on unknown receivers** (`map`, `select`, `uniq`, `dup`): the receiver is unproven at
  most of those sites, and a name spelled by foreign Ruby cannot be joined by name. A receiver-sensitive
  result would need the receiver, which the flow proves at about 60 of the 504 call-result sites, most of
  them names already tracked.
- **`[a, b].max`/`min` (77 rpg2k sites)**: the receiver is an exact Array, but the inline arm's by-name else
  is for non-fixnum elements, and one of 77 sites has all-fixnum elements proven.

### Pre-existing, found while testing, not changed

A class that defines a name twice (`attr_reader :thing` then `define_method(:thing) { ... }`) gets one C++
symbol (`CrHolder_thing_impl`) for both, so a compiled call picks one body and the interpreter the last
definition. It reproduces with both features off. `scripts/bc2cpp_call_results_check.rb` keeps that world in
the generated-code half only.

## Checks

`scripts/bc2cpp_call_results_check.rb`: generated code for every positive, negative and withdrawal above, the
kill switches and the open world; then a compiled fixture against the interpreter in 11 worlds on a
full-core build, a core-only build and (`BC2CPP_MRUBY_FULL32`, run in `bc2cpp-width (int32)`) a 32-bit
`mrb_int` build, with zero dispatches asserted on the exact methods. The driver passes arguments from Ruby:
a parameter pool trusts that every call site is visible, which a C++ caller of the harness is not.
`scripts/bc2cpp_call_results_mutation_check.rb`: six mutants (nil dropped from a reader, a missing pool read
as empty, the two kill switches ignored, the push arm for any exact core class, the Integer-path push for a
Ruby `Array#<<`), all killed. Two conditions have no mutant: the equality of the TYPED trace and the flow
(they are the same data in every world found) and `exact_instances_singleton_free?` (it is inside
`exact_core_value_class` and has its own negative world here).

32-bit `mrb_int`: every fact here is a class claim; `mrb_ary_push` takes a `mrb_value`, and no constant or
mask is converted to an `mrb_int`.

Residual risk: a native gem that writes an ivar or defines a reader through a spelling the scan does not know
would make a reader's class wrong with no guard, the risk ADR 0296 already carries for the pools.
