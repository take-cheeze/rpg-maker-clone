# 261. bc2cpp: join dominance for backward walks, core mixin model, typed-slot reflection

Date: 2026-09-30

## Status

Accepted

## Context

Four items were open after ADR 0254 to 0256, and auditing them found soundness
holes as well as missed sites.

**Backward walks skip joins.** `trace_new_target` (receiver class),
`IvarLayout.trace_type` (ivar type), `proven_array_source_scan`,
`range_return_call`, `nil_literal_write?`, `exact_new_receiver_class` and
`container_phi_merge` take the textually nearest writer of a register. A join
can skip it: `x = h[k] || []` reads `[]` where the register may hold `h[k]`.
ADR 0233 assumed the walk stepped past the branch to an older write and
concluded the sound subset was empty; measured, the walk returns the literal
first. A shadow run against `BytecodeIR.reaching_definitions` over the wio
closed world (`scripts/bc2cpp_barrier_shadow_report.rb`'s approach, hook in the
run) found 115 receiver-class answers and 135 ivar-type answers (Fixnum 103,
nil 27, bool 5) whose reaching definitions disagreed: 250 of about 2,800 sites,
almost all the `x = h[k] || <literal>` family (the other arm a GETIDX, a
method argument, a call result or an ivar). Consumers with a runtime guard cost
a failed compare. The unguarded ones did not:

- `exact_new_receiver_class` gave a direct `Foo_bar_impl` call with no guard for
  `x = Baz.new; x = Foo.new if c; x.bar`, which returned Foo's answer for a Baz.
- The inlined `each`/`collect`/`each_index` loops raised
  `bc2cpp: expected Array receiver` for a Hash or other `each`-able value.
- A typed slot inferred from `@x = h[k] || 0` raised `TypeError` for a Float.

**Typed slots are invisible to reflection, and read 0 before assignment.** The
RData ivar descriptor listed boxed slots only, so `instance_variable_get/set`,
`instance_variables`, `inspect`, `Marshal` and `dup` never saw a typed
(`mrb_int`, `mrb_sym`, `mrb_bool`, Integer-or-nil) ivar: a read gave nil, a
write went to a table the compiled code never read. A typed slot is also
zeroed, so an ivar some path reads before `#initialize` assigns it read
0/false where the interpreter reads nil. In the wio build 63 of 203 typed
fields could be read or exposed before assignment.

**No model of core mixins.** `include Enumerable` marked its class an unknown
mixin. Only `Game::Party` and `LCF::Array2D` include one (nothing includes
Comparable), and core Ruby names (`min`, `positive?`) reached the dynamic path
because the registry sees no definition: 32 `min`, 18 `positive?`/`negative?`
sites, and 51 `max` chains whose fallback dispatched.

**Caps.** Nothing reached `dynamic_candidate_limit`, but the zero-argument RGSS
wrapper sites and `dispose` emitted `compile_poly_small_n(...) || plain
dispatch`, skipping POLY_TABLE. A name past `POLY_SMALL_N_MAX` (16) fell to
plain dispatch there, and diagnostics never counted it: `update` (19
candidates) had 76 such sites, and `dispose` sits at exactly 16.

## Decision

1. **JOIN_DOMINANCE.** `BytecodeIR::Program#write_dominates?(w, use, reg)` holds
   when no edge, jump or exception, enters `(w, use]` from outside `[w, use]`
   and every op stepped over is on the audited write list (the region test of
   ADR 0198, over the IR's edges). `IrepScans#walk_dominating_writers` is a
   walk whose every hop must dominate the read it feeds. `trace_new_target`
   walks with it (`JoinDominance`); a hop that fails ends the walk, and the
   reaching-definitions fallback then accepts only unanimity. Callers that
   guard the class at run time (`compile_send`'s TYPED, MONO and native-wrapper
   traces) pass `guarded: true` and keep the textual answer. `IvarLayout.
   trace_type` checks each hop and on a failed hop joins every reaching
   definition (`@x = c ? 1 : nil` becomes Integer-or-nil, a loop-carried
   counter stays Fixnum through a fixed point where a cycle is the identity).
   `proven_array_source_scan`, `range_return_call`, `nil_literal_write?`,
   `exact_new_receiver_class` and `container_phi_merge` use the same tests, and
   the constant-object edge scan also refuses `JMPNIL` and `JMPUW`.

2. **INIT_ASSIGNED.** `Program#ivar_assigned_before_exposure?(ivar)` is a
   forward must-analysis over the normal and handler edges: is the ivar
   assigned before it is read, before the frame exits and before `self` can
   reach other code (`LOADSELF`, an implicit-self call, `super`, a closure,
   any use of R0)? A `fixnum`, `symbol` or `bool` slot whose ivar fails it
   stays a boxed slot (`demote_typed_ivars_maybe_unassigned`). Integer-or-nil
   needs no proof, its zero is nil.

3. **Typed slots in the descriptor.** `mrb_data_ivar` gets a `kind`
   (`MRB_DATA_IVAR_VALUE` = 0, `INT`, `SYMBOL`, `BOOL`, `INT_OR_NIL`);
   `patches/mruby-rdata-ivar-slots.patch` boxes a typed slot on read, refuses
   another class on write with `TypeError` (the compiled `SETIV` already did),
   refuses `remove_instance_variable` on it, copies it with the payload, and
   the GC marks `VALUE` slots only. bc2cpp lists every slot with its kind and
   asserts that `Bc2cppFixnumOrNil` matches `struct mrb_data_int_or_nil`.

4. **CORE_MIXINS** (`tools/bc2cpp/core_mixins.rb`, `codegen_core_methods.rb`).
   `include Enumerable`/`Comparable` with no closed-world module of that name in
   scope is a known ancestor, not an unknown mixin. Four core Ruby methods are
   modelled by owner, file, normalized body and every other core definer:
   `Numeric#positive?`/`#negative?` (`self > 0`, `self < 0`) and
   `Enumerable#min`/`#max` (`mrblib/enum.rb`, whose only other definer is
   `Range` in range-ext, plus `Time#min` natively). `CoreMixins.verified`
   re-reads the build's own core sources; a changed body, another definer, an
   alias or another native registration turns the model off. Active only in a
   closed world with no global refusal or dynamic installer of the name, and
   only while nothing on the receiver's ancestry (Integer/Float and their
   mixins, or Array/Enumerable/Object/Kernel and theirs) defines the name or
   the methods the body calls, has a prepend or an unknown mixin. The inlines:
   `CORE_NUMERIC_SIGN` (Integer and Float receivers), `CORE_MIN_MAX` (an exact
   `Array` of Integers, or of non-NaN Floats, block-less). The else arm is the
   ordinary dispatch.

5. **module_function copies.** A block no longer disqualifies the copy: the
   copy is self-safe when its body and every nested block are (no ivar, `super`,
   R0 or upvar-0 access). `LCF.write_ber`/`read_ber` (blocks that never look at
   self) become direct calls.

6. **Table fallback everywhere.** `compile_poly_dispatch` is the chain, then the
   table. The RGSS wrapper arms, `dispose` and the index helpers use it.

## Measured

`scripts/bc2cpp_coverage_report.rb`, wio closed world, shipped pass, parent
commit against this change:

| | before | after |
| --- | ---: | ---: |
| generic POLY sites | 467 | 404 |
| `dynamic_no_complete_candidate_set` | 109 | 96 |
| `dynamic_no_registered_definition` | 74 | 56 |
| `dynamic_single_registered_definition` | 283 | 251 |
| chain sites | 2671 | 2663 |
| POLY_TABLE sites (previously plain dispatch, uncounted) | 0 | 76 |
| `CORE_MIN_MAX` / `CORE_NUMERIC_SIGN` | 0 / 0 | 83 / 18 |
| sends kept as dynamic dispatch (cached) | 10185 | 10132 |

Soundness costs: 45 more BLOCK_FALLBACK bodies (335 to 380) as the inlined
loops over `(x || [])`-shaped receivers lose their inline (inlined `each`
loops 177 to 146), CLASS_HINT 303 to 287, FIXNUM_RETURN_PROOF 91 to 78, typed
fields 203 to 140, TYPED sends 515 to 486.

The 109 `dynamic_no_complete_candidate_set` sites were not caused by a missing
mixin model: they have zero candidates because every definition is a singleton
owner, a core native of another arity (`index`, `flash`, `select`) or an
unemitted owner. Thirteen (`LCF.write_ber`/`read_ber`) are fixed by item 5; the
96 left are 41 implicit-self calls in singleton methods, 45 receivers that are
class objects or opaque, and 10 traced classes with no direct target.

## Consequences

- `x = h[k] || []` shapes no longer inline. Sites whose other arm has a class
  fact (an annotated `Hash<Klass>` element, an ivar hint) stay inlined by
  unanimity; annotating the rest recovers them.
- A typed slot refuses another class from `instance_variable_set` with
  `TypeError`, where the interpreter would store it. That is the guard the
  compiled `SETIV` always had.
- Class-id range checks were not pursued: mruby classes are heap pointers with
  no ordering to test against, and POLY_TABLE already turns a long chain into
  one lookup. POLY_SMALL_N_MAX stays 16 (no site reaches
  `dynamic_candidate_limit`).
- Follow-ups: `min`/`max` over Ranges and Hashes, the remaining 251 single-definition
  sites (natives whose bodies read the call frame), and CHA for singleton `self`.
- Verification: `scripts/bc2cpp_join_dominance_check.rb`,
  `bc2cpp_core_mixins_check.rb` and `bc2cpp_typed_reflection_check.rb`
  (host-only sections in `ruby-checks`; the fixtures compare compiled with
  interpreted runs), `bc2cpp_poly_table_check.rb`'s new wrapper section, and
  `bc2cpp_typed_slot_check.rb`, updated for the descriptor. The runtime patch
  changes mruby's own ivar code, so its behavior must be rechecked whenever the
  mruby submodule moves (`scripts/mruby_patch_context_check.rb`).
