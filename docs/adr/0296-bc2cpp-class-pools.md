# 0296. bc2cpp: class pools carry exact classes across ivars and arguments; nil-or-one-class receivers

Date: 2026-10-01

## Status

Accepted

## Context

ADR 0290 turned the else arm of guards on a *stable class constant* into a logged violation and left the
larger families alone: `TYPED`, `IVAR_ACCESSOR`, `MONO_EMBED_GUARD`, `POLY_SMALL_N`/`POLY_TABLE` over a
receiver class that comes from a ClassLayout, annotation or element hint ("whole-program facts, not
proofs", ADR 0210). The request behind this ADR: find which of those hints can be backed by a real
whole-program proof, so the guard disappears (the proof shows it always holds) or its else becomes a trap
(the closed world asserts the class set), and say exactly what blocks the rest.

Measured on the wio closed world (`scripts/bc2cpp_guard_hint_report.rb`, a per-site TSV of
`BC2CPP_GUARD_HINT_REPORT`), master `f70fef67`, 7,361 explicit-receiver sends that chose one of the
families:

| family | sites | else already an error (`bc2cpp_nomethod`) | else kept (dispatch) | guard-free |
| --- | ---: | ---: | ---: | ---: |
| `EXACT_TYPED` / `CLOSED_WORLD_EXACT_CLASS` | 282 | | | 282 |
| `TYPED` | 246 | 162 | 69 | 15 |
| `IVAR_ACCESSOR` | 1,109 | 855 | 41 | 213 |
| `MONO_EMBED_GUARD` | 1,207 | 1,204 | 3 | |
| `POLY_SMALL_N` | 3,014 | 2,268 | 746 (374 by a core/native/singleton/opaque definer, 372 by name) | |
| `POLY_TABLE` | 70 | | 70 (`dynamic_install`) | |
| `ELEMENT` (+ `IVAR_ACCESSOR/ELEMENT`, counted above) | 7 | 5 | 2 | |

Most "hint" guards are already errors: `bc2cpp_nomethod` is a proof about the *name* (every class that
answers it is listed), independent of any receiver hint. What the hints still gate is the 576 kept
class-chain arms (core/native/singleton/dynamic_install/opaque definers may answer), the guard itself
(a compare and a call per site) and, behind ADR 0289's exact-class flow, the receivers it could not carry
across a method boundary: `NumericFlow::OPAQUE` kept class bits out of every pooled ivar and argument. The
unresolved receivers were mostly `@ivar` reads (`get_ivar`: 42 of 69 kept `TYPED`, 30 of 41 kept
`IVAR_ACCESSOR`, 87 of 374 kept `POLY_SMALL_N` chains) and incoming arguments.

## Decision

### 1. CLASS_POOLS: ivar and argument class sets across methods

`tools/bc2cpp/codegen_class_pools.rb` adds two pools to the exact-class flow (`ExactOracle`, ADR 0289), with
ADR 0276's admission rules and its fixpoint, but carrying exact-class bits and `nil`:

- **ivar pools** reuse `NumericIvarGroup`'s structure: one pool per (class family, name), the join of the
  class sets of every `SETIV` of the family. A group is never tracked (`structural`) when a native or foreign
  Ruby source spells `@name`, bytecode names it as a Symbol/String, a block runs it under another `self`
  (`instance_eval`/`define_method` ...), an `attr_writer` writes it, the family has an unresolved superclass
  or an unknown mixin, an irep with no owner or `Object`/`Kernel` touches it, or any reflection with a
  computed ivar name exists. A pool is dropped for good when a `SETIV` stores something the flow cannot name
  (`OTHER`, an exception) or sits in an irep the flow does not model. An unassigned slot reads nil, so the
  entry mask carries `NIL` unless `numeric_ivar_assured?` (every constructor of every class in the cone
  assigns it before `self` can escape, no `allocate`), and always inside an `initialize` body, blocks
  included.
- **argument pools** reuse `entry_arg_candidates`: a mandatory argument of a name with one definition, called
  only from visible same-arity sites, with no `send`/`alias`/Symbol-literal or computed-name way to reach it.

Everything needs `ClosedWorld#exact_instances_singleton_free?` (ADR 0280). `BC2CPP_CLASS_POOLS=0` turns it all
off; `=strict` also withdraws the pools whenever any Ruby in the build can reach `Marshal`.

### 2. Consumers

- **Exact**: a receiver whose pooled set is one class (no nil) is an exact receiver for everything ADR
  0289/0280/0281 already do with one: `EXACT_TYPED`, `CLOSED_WORLD_EXACT_CLASS`, exact core arms, and
  `INDEX_EXACT` (`x[i]`, `x[i] = v` on an exact Array/Hash lose their class test; `GETIDX`/`GETIDX0`/`SETIDX`).
- **NILABLE_RECEIVER** (`codegen_nilable_receiver.rb`): a receiver whose set is nil plus one class K (`@ui = nil`
  in `initialize`, `@ui = { ... }` later; `@interpreter`) is compiled as
  `if (mrb_nil_p(r)) { nil arm } else { exact-K path }`, the non-nil path compiled with the nil bit of that one
  register removed from the flow. It applies to plain `SEND`/`SEND0` (when the exact path sheds dispatches or
  class tests) and to `GETIDX`/`GETIDX0`/`SETIDX`.
- **NIL_RECEIVER**: the nil arm is `bc2cpp_nil_receiver` (a cold helper: it dispatches, so mruby raises its own
  `NoMethodError` with its own message, and a dispatch that *finds* a method raises a `RuntimeError` naming the
  broken proof) when `nil_unanswerable?(name)`: no Ruby definition of the name on nil's ancestors
  (`ForeignDefiners` per class, the registry, dynamic installers), no `method_missing` there, and every native
  registration of the name, read from the build's own sources that spell it, belongs to a resolved class that
  nil does not descend from. Otherwise (`nil.to_s`, a world `NilClass#foo`) the nil arm stays a send. The sites
  are listed on stderr (`NIL_RECEIVER_SITE`), not gated: a nil dereference is a program path, not a dead one.
- **Native exact**: an exact RGSS native receiver (`@bitmap.fill_rect`) calls its registered entry point
  (`native_exact_direct_code`, ADR 0281), dropping the `mrb_integer_p` test of an argument
  `proven_fixnum_operand?` proves.

### 3. What was not built, and why

- **(3) element classes.** Not provable. An Array/Hash is a mutable, aliasable heap object, and its element class
  is the join of every store through *every alias*: `push`, `<<`, `[]=`, `concat`, `insert`, `fill`, `replace`,
  a block parameter that mutates it, a native that stores into it. Nothing in bc2cpp has points-to or escape
  information; ADR 0285's record-hash proof works only because the stores are literal-key writes to a slot and
  it still refuses 53 of 57. An element hint that is wrong costs one failed compare today; promoting it needs a
  whole-program alias analysis. The family is 7 `ELEMENT` + 117 `IVAR_ACCESSOR/ELEMENT` sites; 0 converted.
- **(4) complete subclass set of a frozen hierarchy.** For `self` this is CHA_SELF (ADR 0254), already done. For
  any other receiver the proof "the candidate set equals the hierarchy" is useless without "the receiver is in the
  hierarchy", which is the receiver class-set proof above: after this change 331 of the 371 kept `POLY_SMALL_N` sites
  (89%) have a receiver set that still contains an unmodelled class (`OTHER`: a call result outside the return table, an
  argument with an unvisible caller, a captured local). The `singleton_definer` reason (160 sites) is about
  the *name* (`Graphics.update` next to `window.update`), which only a "receiver is not a class object" fact
  removes; that fact comes from the same set.
- **Multi-class sets** (`POLY_SMALL_N` over an ivar holding {A, B, nil}) would turn the chain's else into a
  violation trap. 4 kept sites in the wio build have a fully known multi-class set; not implemented.

## Withdrawal conditions

| condition | what withdraws | negative case |
| --- | --- | --- |
| attr_writer / attr_accessor for the ivar | that ivar's pool | `read_written` |
| `instance_variable_set(:@x, ...)`, `'@x'` literal, native/foreign source spelling `@x` | that ivar | `read_refl`, native/foreign variants |
| `instance_variable_set` with a computed name, `instance_eval`/`class_eval` without a literal block | every ivar pool | variants |
| `define_method`/`instance_exec` block touching the ivar | that ivar | variant |
| singleton maker (`def obj.x`, `singleton_class`, `extend` on an object) | everything (ADR 0280) | variant |
| `allocate`, a constructor path that skips the assignment, a read inside `initialize` | exactness (nil joins the set) | `read_lz`, `allocate` variant |
| a second class stored, a parameter stored | the ivar is not exact | `read_mixed`, `read_param` |
| `alias`, `send(:name)`, Symbol literal or computed name reaching a method | its argument pool | `pl_use_alias`, `pl_use_send` |
| an argument site of another class | that argument pool | `pl_use_two` |
| `method_missing` anywhere | the nil arm's `nil_unanswerable?` (and ADR 0210's refusals) | variant |
| prepend/extend/include of a module defining the name | `closed_world_exact_target`'s lookup (ADR 0289) | return-class check |
| subclassing the pooled class outside the world | `exact_class?`/wild families | `ClosedWorld` |
| `dup`/`clone` | none needed: a copy holds the same classes; `initialize_copy` stores are `SETIV` sites | |
| `Marshal.load` | not modelled by default (see risk); `BC2CPP_CLASS_POOLS=strict` withdraws | strict variant |
| open world, no `NATIVE_SRCS`/`FOREIGN_RUBY_SRCS` scan | everything | open-world variant |

## Consequences

Measured on the wio closed world, three gems, shipped codegen (`scripts/bc2cpp_coverage_report.rb` and
`scripts/bc2cpp_dynamic_site_census.rb`; `BC2CPP_CLASS_POOLS=0` is the "before", same master `f70fef67`):

| | before | after |
| --- | ---: | ---: |
| `bc2cpp_send` call sites in generated methods (census) | 5,027 | 4,236 |
| cached send sites (coverage report) | 5,499 | 4,708 |
| `TYPED` behind a class guard with a send fallback | 246 | 101 |
| `EXACT_TYPED` guard-free calls | 246 | 387 |
| `IVAR_ACCESSOR` guard-free / kept dispatch / error else | 213 / 41 / 855 | 316 / 25 / 776 |
| `NILABLE_RECEIVER` sites (each with a `bc2cpp_nil_receiver` arm, not a send) | 0 | 805 |
| `INDEX_EXACT` arms | 121 | 831 |
| class pools | 0 | 171 ivar, 58 argument |
| `core_tag_chain_else`, receiver an ivar (census) | 829 | 277 |
| `rgss_native_exact_class_else` (census) | 587 | 567 |
| `NOMETHOD_REVIEWED` keys | 3,118 | 2,930 (188 fallbacks became unreachable; none added) |

Per family (sites, provable, converted), wio build:

| family | sites | provable | converted |
| --- | ---: | ---: | ---: |
| (1) ivar class proofs (every family, receiver an `@ivar`) | 1,685 sites, 202 of them with a kept dispatch | 171 of 884 ivars pooled: 126 exact, 45 nil-or-one-class | kept dispatch 202 -> 158; guard-free `TYPED`/`IVAR_ACCESSOR` +141; 805 sites nil-tested |
| (2) entry-argument pools | 1,448 candidate arguments, 1,884 sites with an incoming-argument receiver | 58 pools | counted in the rows above and below; no separate count |
| (3) element classes | 124 | 0 | 0 (obstacle above) |
| (4) frozen-hierarchy POLY sets | 371 kept `POLY_SMALL_N` + 70 `POLY_TABLE` | 4 with a fully known multi-class set; 331 of 371 have an unmodelled class in the receiver set | 0 |

ADR 0295 measured argument-class pooling alone (on `closed_world_exact_target` receivers) at about zero sites and did not
adopt it; the 58 argument pools here are consistent with that (they are a small part of the change), and the
gain comes from the ivar pools and the nil-or-one-class consumers it did not have. The sites removed are the
census's `core_tag_chain_else:receiver_is_ivar` family (`docs/bc2cpp-dynamic-site-census.md`).

The `MONO_EMBED_GUARD` family (1,207 sites) is unchanged: 1,204 are already error arms, and its receivers are not
ivar reads. The optcarrot probe (open world) is byte-identical: its coverage report is equal with the pools on and
off, since every proof needs the closed world.

Residual risk, stated plainly:

- A pooled class is an *unchecked* direct call. A writer the scan cannot see turns it into a crash or a wrong
  answer, not a logged violation: `scripts/bc2cpp_class_pools_check.rb` pins this (an `@box` written from C++
  behind the analysis' back makes the compiled exact read crash where the interpreter answers; the kill switch
  restores agreement). The invisible writers are `Marshal.load` of hostile bytes, native code that builds the
  ivar name at run time, and a helper-function native definition the registration scan does not model. The first
  is the same residual as ADR 0276/0279/0285; the engine does `Marshal.load` its own save format, so
  `BC2CPP_CLASS_POOLS=strict` is the conservative setting.
- Native registrations are read per file from the build's own sources by the existing scan; a NilClass method
  defined through a helper that takes the name as a literal would be missed (the same blind spot as every other
  native-name proof).
- Mruby threads are not modelled (an ivar write between two instructions of a method with no call); the engine
  builds have no thread gem.
- No 32-bit `mrb_int` target was built here beyond the host runs of the new check with `-DMRB_32BIT
  -DMRB_INT32`: no mask or constant reaches an `mrb_int`, and the generated code adds no integer literal.
- Firmware smoke runs (psp, wio, maix) and CI were not run.

## Tests

`scripts/bc2cpp_class_pools_check.rb` (generated code: positives, a negative world per withdrawal condition, kill switch, strict
Marshal, open world; behaviour on real mruby, interpreted against compiled including nil receivers, in a
full-core, core-only and 32-bit `mrb_int` build, and the documented outside-writer failure),
`scripts/bc2cpp_class_pools_mutation_check.rb` (seven mutants of the soundness conditions, each must be caught),
`scripts/bc2cpp_guard_hint_report.rb` (the per-family census above) and the updated
`scripts/bc2cpp_return_class_check.rb`, `scripts/bc2cpp_nomethod_reviewed_check.rb`.
