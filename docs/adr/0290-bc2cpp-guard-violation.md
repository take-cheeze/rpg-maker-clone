# 0290. A guard on a stable class constant fails with a logged error, not a dispatch

Date: 2026-10-01

## Status

Accepted

## Context

Most guarded call sites in bc2cpp output end in `else bc2cpp_send(...)`. The request
behind this ADR: where the closed-world analysis claims a guard's class set is closed,
a guard violation should be an error, not a quiet fallback dispatch.

Classifying every `bc2cpp_send` of the wio closed-world build (all three compiled
gems, `BC2CPP_GUARD_VIOLATION=0`, 9,734 sends in the C++, 10,181 cached send sites in
the coverage report) shows that most of the class-set claims are already errors, and
that the rest are not claims:

| else arm | sends | what the analysis knows |
| --- | ---: | --- |
| `bc2cpp_nomethod` (ADR 0210/0226, not a send; `NOMETHOD_REVIEWED`) | 4,694 | class set proven closed; already an error |
| class chain kept: `core_or_native` | 338 + 6 | a core or native class answers the name too (`size`, `[]`, `call`...); the else is live |
| class chain kept: `singleton_definer`, `dynamic_install`, `opaque_definer`, `unlisted_class` | 168 + 77 + 2 + 2 | a singleton, an installer or an opaque class may answer; live |
| class chain, no `site` model | 24 | no closed-world site |
| Fixnum/Float/Integer arms (`FIXNUM_*`, `INTEGER_*`, `FLOAT_*`, `ARRAY_PUSH`, argument tags of NATIVE_DIRECT) | about 4,550 | Float, Bignum, overflow and user `Numeric` are valid; excluded by the request |
| exact core-type guards (`mrb_hash_p(x) && x->c == M->hash_class`...) | about 1,740 | a subclass, `nil` or a user class with the name is a valid receiver; the receiver is a hint |
| native exact-class arms (`rgss::native_sprite_class()`...) | 497 | of which 204 were `X.new` identity guards (below); the rest dispatch for any other class |
| `NEW_IDENTITY`: `Klass.new` constant identity | 273 (56 generic, 217 native) | see Decision |
| `CLASS_ARGUMENT`: `is_a?`/`kind_of?` class test | 55 | see Decision |
| class-matched arms (`if class == K { send }`) | about 1,300 | the receiver IS K and K's definition is dispatched; not a guard else |
| ADR 0269 root-context arms, BLOCK_CORE_DIRECT else | 345 | Fiber frames take the dispatch |

The compiler's receiver-class traces (`TYPED`, `IVAR_ACCESSOR`, `MONO_EMBED_GUARD`
over a ClassLayout, annotation or element hint, `POLY_SMALL_N` over a traced
receiver) are guarded *because* they are hints (ADR 0210: "whole-program facts, not
proofs"). A failing guard there reaches a correct program with a subclass or another
class, and the else arm dispatches to a real method. Making it an error would turn
every wrong hint into a crash of a program that is correct, so those stay.

What is proven is narrower: a register that every reaching definition fills with a
`GETCONST` of a constant `StableClassConstants` (ADR const-site cache) or
`constant_object_owner` (ADR 0259) proves to name one class or module for the life of
the VM. Three guards test exactly that fact and nothing else.

## Decision

`bc2cpp_guard_violation` is emitted instead of the dispatch in the else arm of:

- `NEW_IDENTITY`: the class-identity test of `Klass.new` (`mrb_class_ptr(recv) ==
  Klass`) in the generic `mrb_obj_new` arm, the native RGSS construct arm (`Rect`,
  `Color`, `Tone`, `Bitmap`, `Sprite`, `Table`), the compiled-construct arm and the
  keyword construct arm, when the receiver register is the stable constant naming
  `Klass`. The argument-tag test of `Bitmap.new` keeps its dispatch (a String is the
  file-load form).
- `CLASS_ARGUMENT`: the `mrb_class_p(arg) || mrb_module_p(arg)` test of
  `is_a?`/`kind_of?`, when the argument register is a stable class or module constant.
- `CLASS_EQQ`: the `default:` of the `===` type switch, when the receiver register is a
  stable class or module constant.

The proof is `CodeGen#stable_constant_register`: closed world only, no global
refusal, no literal block, a plain `SEND`/`SEND0` of that name (an inlined loop body
that substitutes its receiver or arguments gets none), at most 16 arguments, and
`agreed_constant_name` (reaching definitions through joins and loops) names a bare
constant in `stable_class_constants` or a class `constant_object_owner` proves. The
class set is closed because a stable constant denotes one object: there is no other
class the register can hold. Open worlds, hint-only receivers, numeric arms, core-type
guards, native-class chains, class chains with a kept reason, Fiber root-context arms
and BLOCK_CORE_DIRECT else arms keep their fallback.

`bc2cpp_guard_violation(M, recv, i, "Owner#method (FAMILY)", argc, ...)` (SymbolCache,
out of line like `bc2cpp_nomethod`) never dispatches: it writes
`[RPG2k] closed-world guard violation: <Class>#<name> at <Owner#method (FAMILY)>` to
`$stderr` and raises `BC2cppGuardViolation < NoMethodError`, so a `rescue
NoMethodError` or `StandardError` written for the old path still sees it, after the
log line. `-DBC2CPP_NOMETHOD_VERIFY` aborts instead (ADR 0275), naming the class,
name and site.

Reviewed list: a site is marked `/* CLOSED_WORLD guard-violation: name */` and listed
on stderr (`GUARD_VIOLATION_SITE Owner#method -> name`), but it is deliberately NOT
held to `NOMETHOD_REVIEWED`. A first version did and failed
`scripts/bc2cpp_nomethod_reviewed_check.rb`: which of these sites exist depends on
which callees compile (an initializer that compiles gives an unguarded direct
construct; one that does not leaves the guarded `mrb_obj_new` arm), so the hot-only
build, which is the one that ships, has sites a full build lacks and the list's
"every entry is a site in the full run, every hot-only site is an entry" contract
cannot hold. The proof is the gate here, and verify mode is the review.

Kill switches: generator `BC2CPP_GUARD_VIOLATION=0` emits the old dispatch (the send
count rises by exactly the converted count, checked); compile-time
`-DBC2CPP_GUARD_VIOLATION_DISPATCH` makes the helper dispatch by name (silently, as
before) for debugging a suspected wrong proof.

## Consequences

Measured on the wio closed world, all three gems, full (not hot-only) codegen:

| | before | after |
| --- | ---: | ---: |
| cached send sites (coverage report) | 10,181 | 9,874 |
| `bc2cpp_send(` in the C++ | 9,734 | 9,427 |
| `bc2cpp_guard_violation` sites | 0 | 307 (267 `NEW_IDENTITY`, 40 `CLASS_ARGUMENT`, 0 `CLASS_EQQ`) |
| `NOMETHOD_REVIEWED` keys | as master | unchanged (violation sites are listed, not gated) |

So 307 of about 9,700 dynamic sends (3%) became errors. The remainder is not
convertible without a stronger proof: converting it would change what a correct
program observes, or would trust a hint. The generated file passes
`g++ -fsyntax-only -DMRB_INT32`. The helper's argument is one more string pointer per
site; shipped hot-only firmware compiles none of these sites (ADR 0226).

Residual risk:

- The conversions are exactly as sound as `StableClassConstants` (one `class`
  statement, no assignment, no `const_set`/`remove_const`/`autoload`, native names
  defined once) and `constant_object_owner`. A hole there used to cost a dispatch to
  the new constant's value; it now costs a logged `BC2cppGuardViolation`.
- Firmware smoke runs under `BC2CPP_NOMETHOD_VERIFY=1 BC2CPP_HOT_ONLY=0` (psp, wio,
  maix: toolchains and emulators) were not run when this was written, and the desktop
  game smokes and optcarrot build open worlds that have no violation site. The
  evidence is the wio codegen, the check below against a real mruby, and the proof.
- Extending the family needs a new proof, not another gate on a hint. Receiver
  guards whose class comes from a ClassLayout, annotation or element hint are the
  largest remaining group and would need a proof that the hint is exact.

`scripts/bc2cpp_guard_violation_check.rb` (CI `bc2cpp-checks`, fast shard) covers the
gate, the generated code (converted, not converted, kill switch one for one, open
world) and, against a real mruby, the in-set program (compiled equals interpreted, no
log), a program with constants rebound from outside the analysed world (logged
`BC2cppGuardViolation` where the interpreter carries on or raises a `TypeError`),
the dispatch define and verify mode.
