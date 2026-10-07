# 0370. bc2cpp: setter-site class pools, and a checked receiver arm for what they prove

Date: 2026-10-07

## Status

Accepted

## Context

The by-name `bc2cpp_send` sites that remain in generated method bodies are mostly sends whose receiver class set is
unproven (ADR 0331, 0341). Wio closed world, branch base `8ab8aa75`, shipped pass of
`scripts/bc2cpp_coverage_report.rb`: 2,286 `bc2cpp_send` sites in bodies, of which 814 are `core_tag_chain_else` on a
receiver that is not an ivar, 215 the same on an ivar, 206 `rgss_native_exact_class_else`. The request was to type
more of those receivers soundly: every new proof runtime-checked (`bc2cpp_guard_violation`, never a guard-free arm),
a kill switch, a negative-world check. Three pieces were proposed; each was measured before building (the
receiver-proof report of ADR 0331 on the same tree, with a new `accessor:ivar_accessor[...]` reason added locally):

1. **Return-class sets of getters over `@x || []` / `@x ||= []`.** The return table already joins every definition
   of a name; what it lacks is the ivar's class pool (ADR 0295). Of the 170 unproven sites a receiver proof would free
   outright, the call-result ones that reach an ivar accessor are `contents` 18, `bitmap` 11, `map` 9, `teleport_targets`
   and `items` 2 each. Their pools are not dropped by an unmodelled `map`/`compact` result but by **who may write the
   slot**: `structural:writer` (an `attr_writer`/`attr_accessor` the pool refuses),
   `no_group` (a slot only an audited native writes: `@contents` of `RGSS::Window`, `@bitmap` of `Sprite`/`Plane`),
   and a setter whose name has several definitions (`RPG2k::Window#contents=`). That is the piece with a closed
   shape, and the one built.
2. **Element and tuple-slot typing.** Not built, and for `@list` not provable. `@list` is stored from `commands || []`,
   from `cmds` (a call on the externally supplied `@resolver`) and from `@call_stack.pop`, whose entries are pushed as
   `[@list, ...]` and also rebuilt by `restore_call_stack(frames)` as `[f[:commands] || [], ...]` from a caller-supplied
   Hash of frames: slot 0 is an element of data nobody in the closed world writes. A checked arm for it would raise on
   a malformed save and prove nothing else. The freed-by-element population is 8 sites (`element` source) plus 21
   block parameters (`@allies.each { |a| a.actor }`) that need `@allies`' element class *and* `Combatant#@actor`
   (`@actor = actor`, the 11th optional parameter of a 20-parameter `initialize`); ADR 0312 priced the container
   machinery at the size of ADR 0285 for fewer than 30 sites, and this run's numbers agree.
3. **Integer-ness of `x=`/`y=` arguments.** Not built. 72 of the 206 native sites are `x=`/`y=` (62 are `new`), and
   the else is not dead: a Float argument is legal (`mrb_get_args "i"` truncates it). The unproven operand is a
   camera offset, an LCF command parameter or an attribute of another object (`vpx - cam_x - 12`), roots ADR 0311 ranked
   at 13% or less each as an upper bound; no closed proof exists for them.

## Decision

### SETTER_POOLS: the join of the arguments of every call of `x=`

Every way to call a setter is a send named `x=`. `CodeGen#setter_pool_reads` is the argument register of every such
send of the closed world (`entry_arg_call_index`), admitted only when (`compute_setter_pool_refusal`): no `:x=` Symbol
is spelled (`send(:x=)`, `alias_method`, `method(:x=)`, a `define_method(:x=)` poison it; the `alias` keyword poisons
its old name) and no String spells it; no definition is foreign or installed out of sight (`unknown_def?`); every
Ruby definition takes exactly one mandatory argument and none calls `super` (a forwarded value would bypass the
sites); every site passes
one argument; the name is not funcalled by a native source, spelled by foreign Ruby, or spelled by a native string
literal other than the method name of its own registration (`ClosedWorld#record_native_other_literals`: a
`mrb_define_method(M, cls, "contents=", ...)` is a definition, not a call). `numeric_dynamically_named?`'s clause "any
computed-name send refuses every `stem=`" (mruby's own `Symbol#to_proc` has one, so it refused 394 of 553 setters)
is **not** an admission rule here: a composed name that stores another class is a guard violation at the reader.

Three consumers join the sites into pools:

* an ivar group the numeric proof refuses only because an `attr_writer` writes it (`NumericIvarGroup#checked`);
* an ivar only an audited native writes (`NativeIvarScopes::STORES`: `@contents` of `RGSS::Window`, written by
  `window_init` with a 1x1 `RGSS::Bitmap` and by `window_set_contents` with its one argument unchanged; the digest-pinned
  `lib.cxx` is re-read by `scripts/bc2cpp_setter_pools_check.rb`, which fails when the stores differ);
* the parameter of a Ruby setter definition whose name has several definitions.

### CHECKED provenance and CHECKED_POOL_EXACT: a proof that is a test, not a promise

A class pool built this way is seeded with `NumericFlow::CHECKED` (bit 319, inside `OPAQUE`, below the LCF kinds). It
is not a class: every decoder in the tree reads a class from a mask **equal** to one class bit (`return_class_of_mask`,
the union plans, `escape_receiver_classes`, `receiver_instances`, `native_result_flow_mask`), so a mask that carries it
is unproven everywhere and joins into other pools as unproven-but-tracked. The one reader is
`CheckedPoolReceiverSend`: a `SEND`/`SEND0` whose receiver mask is `CHECKED` + nil and/or one non-core class K is
compiled twice, as before and with `exact_flow_class` answering K for that register (`@checked_pool_override`, a
`METHOD_COMPILE_STATE` variable); when the second has an exact arm and fewer by-name dispatches it replaces the first:

```
// CHECKED_POOL_EXACT :width -- receiver is nil or exactly RGSS::Bitmap by a checked setter-site pool (ADR 0370) ...
if (mrb_nil_p(r6)) { r6 = bc2cpp_nil_receiver(M, r6, 253); }
else if (mrb_obj_class(M, r6) == rgss::native_bitmap_class()) { <the exact arm, no dispatch> }
else { r6 = bc2cpp_guard_violation(M, r6, 253, "<Owner>#<method> (CHECKED_POOL_EXACT)", 0); }
```

So a writer the scan missed (a native `mrb_funcall` of the setter outside the scanned sources, a composed name, a
Marshal-built object) is a logged `BC2cppGuardViolation` (< NoMethodError) at the first read, and
`-DBC2CPP_GUARD_VIOLATION_DISPATCH` restores the dispatch for debugging. The nil arm is the helper of ADR 0296
(`bc2cpp_nil_receiver`) when no nil method has the name, else the ordinary send.

### Aliased names: operands for a checked accessor only

`numeric_aliased_names` withdraws every Symbol of an irep that aliases anything, so `attr_reader :contents` in the
class body that also holds `alias_method :_rgss1_initialize, :initialize` was never a return-table candidate. For a
name whose every definition is an `attr_reader` of a checked pool, only the operands an aliasing send spells
(`aliased_operand_names`: `ALIAS`, `alias_method`, `alias`, `define_method`, `define_singleton_method`, Symbol literals
only; any other operand keeps the irep-wide rule) withdraw it, and it joins the table only once its pool carries
`CHECKED` (`admit_checked_alias_names`, inside the existing fixpoint). Every other name keeps the old rule, so no
unchecked fact is added.

### Kill switch

`BC2CPP_SETTER_POOLS=0` (also off with `BC2CPP_GUARD_VIOLATION=0`, `BC2CPP_CLASS_POOLS=0` or an open world) restores the
earlier output byte for byte: `shipped.cxx` of the shipped pass is `cmp`-identical to the base tree.

## Measured

Wio closed world, shipped pass of `scripts/bc2cpp_coverage_report.rb`, `BC2CPP_SETTER_POOLS=0` against the default on the
same tree, counted by `scripts/bc2cpp_dynamic_site_census.rb`. Two trees, because master moved under the branch:

| Measure | Branch point `8ab8aa75`, off (= base) | on | Delta | master `16e2bc43`, off (= master) | on | Delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 2,286 | 2,259 | -27 | 2,208 | 2,197 | **-11** |
| `mrb_funcall_with_block` | 414 | 414 | 0 | 414 | 414 | 0 |
| `bc2cpp_nomethod` sites | 4,460 | 4,458 | -2 | 4,541 | 4,539 | -2 |
| `CHECKED_POOL_EXACT` arms | 0 | 25 | +25 | 0 | 9 | +9 |
| checked ivar / argument pools | 0 | 34 / 11 | | 0 | 34 / 11 | |

Off is `cmp`-identical to the tree without this change on both trees (the kill switch is byte for byte).

Body `bc2cpp_send` sites by name, the ten largest and every name that changed (branch point, then master):

| Name | Base off | on | Master off | on |
| --- | ---: | ---: | ---: | ---: |
| `[]` `empty?` `size` `to_s` `length` | 208 202 176 151 69 | same | 207 202 177 151 69 | same |
| `new` `to_enum` `to_i` `[]=` `push` | 66 66 60 51 50 | same | 66 66 60 51 51 | same |
| `width` | 47 | 34 | 0 | 0 |
| `height` | 33 | 30 | 0 | 0 |
| `x=` / `y=` | 44 / 44 | 42 / 42 | 44 / 44 | 42 / 42 |
| `name` | 37 | 35 | 37 | 35 |
| `clear` | 7 | 5 | 7 | 5 |
| `blt` / `fill_rect` / `text_size` | 7 / 7 / 4 | 6 / 6 / 3 | 7 / 7 / 4 | 6 / 6 / 3 |

At the branch point the largest part of the gain was `width` (-13) and `height` (-3) after `win.contents`, whose else was
a by-name send behind a `singleton_definer` marker (91 to 75 in that category). PR #2050 (ADR 0369, identity arms for
module singleton definers) merged first and removed those elses for every receiver (91 to 10), so on master the
same receivers are already direct and the pools shed only what the singleton arms could not: `x=`/`y=` on
`Game::Character` and the Bitmap drawing calls `clear` `blt` `fill_rect` `text_size` (nine sites of the
`rgss_native_exact_class_else` row, 206 to 197), and `name` on `Game::Shop` (two of `core_or_native`, 188 to 186). The two `core_tag_chain_else` rows (820, 216 on master) do not move.
The 62 `contents=` sites all pass a Bitmap, so the `contents` pools of `RGSS::Window`, `RPG2k::Window` and
`MessageState` are exact; the arms that remain are the ones whose by-name else was not a singleton arm.
**-11 of 2,208 is 0.5%** (-27 of 2,286, 1.2%, before PR #2050): below the 30 that ADR 0331 set as the bar, and the
three largest unproven populations (call results of `map`/`to_s`/`new`, parameters without a visible caller,
container elements) are untouched.

What the pools do not free, from the same run: `bitmap` (11 sites) needs seven of its 31 `bitmap=` sites typed (a
parameter, a cache call); `map` (9) is a name `Array#map` also answers, so it is no return-table candidate; 16
of the setters a pool depends on are refused (10 poisoned by a Symbol, 6 called by a native or foreign source) on the branch-point tree.

## Checks

* `scripts/bc2cpp_setter_pools_check.rb` (CI shard `setter-pools`): the native store audit; generated code for the
  positives (`attr_accessor`, `attr_writer`, a setter with two definitions, an accessor call result, a name a native
  only registers) and the negative worlds (two classes, a parameter site, `send(:x=)`, `alias_method`, a String
  spelling, a native `mrb_funcall`, `MRB_SYM_E`, foreign Ruby, a runtime `define_method`, `super`, two arguments,
  `instance_variable_set`, a singleton, an aliased operand, an unchecked name next to an alias), `method_missing`, the
  three kill switches and the open world; then the fixture on a full-core mruby, interpreted against compiled
  (identical answers, nil receivers raising the interpreter's NoMethodError), and the two failure modes as
  **loud**: a setter called from outside the closed world and a composed name `send("#{stem}=")` each end in
  `BC2cppGuardViolation` where the interpreter answers, and the kill switch makes the outside call match again.
* `scripts/bc2cpp_setter_pools_mutation_check.rb`: eleven mutants, one per admission rule, the provenance bit, the
  class test, the nil arm, the mixed-set decoder and the alias rule.
* `scripts/bc2cpp_aliased_names_check.rb`: the operand set and the computed-operand fallback.
* Not run: a 32-bit `mrb_int` leg (nothing here touches an integer constant or a codec; the new Ruby is host-side tooling),
  and no `-DMRB_NO_GEMS` core-only leg, because the fixture needs `send` and `alias_method`.

## Consequences

* A pool that only a setter writes can now type a receiver, at the price of one class test and a loud failure where
  a writer the scan cannot see exists. The failure is not new risk relative to ADR 0295's unguarded pools; it is the same
  assumption made checkable, and only for the pools this ADR builds.
* `numeric_dynamically_named?` is unchanged for every other proof. A future proof that wants setter sites reads
  `setter_pool_reads`.
* The three pieces the request ranked are answered: getters over `@x || []` are limited by who writes the slot, not
  by the return table, and the writer-only slice is built; element/tuple-slot typing and argument Integer-ness are not
  provable from the closed world's own data and are not built (see the Context).
* New `CodeGen` ivars (`@setter_*`, `@checked_pool_override`, `@aliased_operand_names`, `@rc_*_alias_names`) are
  classified in `scripts/bc2cpp_nested_compile_state_check.rb`.

## Triggers to revisit

* `@bitmap` (11 sites): type the seven `bitmap=` sites (a `cached_bitmap` call result and parameters) and add
  `bitmap=` to `NativeIvarScopes::STORES` after auditing `spr_set_bmp`/`plane_set_bmp_native_body`.
* The 21 `@allies`/`@actor` block-parameter sites, if ADR 0312's container machinery is built for another reason.
