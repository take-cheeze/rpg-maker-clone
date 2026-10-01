# 0302. bc2cpp: RGSS native result facts and instance receivers

Date: 2026-10-01

## Status

Accepted

## Context

NumericFlow (ADR 0276) drops the dynamic send from a guarded arithmetic or compare arm only when both
operands are *proven* Integer/Float, and the Fixnum proof (ADR 0279) drops the `mrb_fixnum_p` tests the
same way. Neither knew anything about an RGSS native entry point: `bitmap.width`, `rect.height`,
`color.red`, `bitmap.text_size(s).width` came back as "unknown", so `x += c.text_size(label).width` kept a
Fixnum/Float/slow-path ladder. The exact-class flow (ADR 0289, 0296) already knew `Bitmap.new` (a stable
class constant plus a standard constructor lookup) and carried it through ivars and arguments, but had no
rule for what a *call* on such a receiver returns.

Two related blockers sat in the same census (`docs/bc2cpp-dynamic-site-census.md`, items 4 and 6):

- A guard chain whose name has a `def self.x` definer (`Graphics.width` next to `Window#width`) kept its
  by-name else (`kept: singleton_definer`) for every receiver that is not `self`, even when the
  exact-class flow had proven the receiver holds only instances of a few project classes.
- The zero-argument RGSS wrappers (`width`, `height`, `rect`, `x`, `red`, ...) emitted their class-guard
  arms before the exact-class path got a look, so an ivar-held `Bitmap` still went through
  `native_bitmap_class()` / `native_rect_class()` tests and a `POLY_SMALL_N` tail.

## Decision

### 1. `NativeResultFacts`: audited result kinds per (owner, name)

`tools/bc2cpp/native_result_facts.rb` declares what a call that *returns* from an RGSS native hands back:

| owner | names | kind |
| --- | --- | --- |
| `RGSS::Bitmap` | `width`, `height` | `:fixnum` (`mrb_fixnum_value`) |
| `RGSS::Bitmap` | `rect`, `text_size` | an exact `RGSS::Rect` (`mrb_obj_new` of that constant's class) |
| `RGSS::Rect` | `x`, `y`, `width`, `height` | `:fixnum` |
| `RGSS::Color`, `RGSS::Tone` | `red`, `green`, `blue`, `alpha` / `gray` | `:float` (`mrb_float_value`) |

A fact is audited, not inferred. It pins the registration's callee text and the chain of C functions down to
the one whose `return` statements decide the result. `scripts/bc2cpp_native_result_facts_check.rb` re-reads
`mruby-rgss/src/*.cxx` and fails when the registration is not unique and verbatim, when a link of the chain
stops delegating, or when any `return` loses the kind's shape; seven source mutants (a `nil` return, a
Float return, another class, another callee, a second registration) must each be rejected.

Deliberately not declared, because the result is not one class on every path:

- `Viewport#rect`, `#ox`, `#oy`: an unassigned ivar reads `nil`.
- `Window`/`Plane` readers (`x`, `y`, `width`, `z`, ...): Ruby `attr_reader`s of ivars the natives write only
  once a setter has run.
- Every setter and drawing call (`x=`, `y=`, `z=`, `fill_rect`, `draw_text`, `blt`, `clear`): the natives
  return `self`, and a bytecode assignment `a.x = v` evaluates to `v` without reading the send's result, so a
  fact would be dead. The *arguments* of those entry points are unaffected: an `:int` argument still needs a
  Fixnum proof (`mrb_get_args "i"` coerces a Float), which `native_fixnum_result?` now feeds from the getters
  above.
- `Bitmap.new`: already an exact `RGSS::Bitmap` through ADR 0289/0296 (`RETCLASS`/`CLASSIVAR`), no table row.

A fact applies to a send only where lookup provably reaches the registration:

- **Exact receiver** (`codegen_native_results.rb`). The exact-class flow proves the receiver's class, the
  class has exactly one parsed registration of the name, no Ruby definition, no prepend
  (`native_exact_owner_safe?`, the proof NATIVE_EXACT_DIRECT already uses), and `exact_instances_singleton_free?`
  holds. A receiver set with several classes joins their facts (a class without one makes the result
  unknown); `nil` contributes nothing only where `nil_unanswerable?`.
- **Name only** (`text_size`). When *every* definition of the name is an RGSS native with a fact or a Ruby
  body the numeric/return-class tables can model, and nothing else in the build spells the name, the name
  joins `numeric_return_candidates` with the join of its owners' kinds, so the result is known whatever the
  receiver (`ClosedWorld#name_visible_except_natives_in?`).
- **A class result** is `RGSS::Rect` as the constant names it. `ClosedWorld#native_class_constant_stable?`
  requires exactly one outside write binds the simple name (the native definition itself), no bytecode
  `SETCONST`, and no dynamic constant mutation; `Rect` is never reopened in Ruby, so the existing
  `ConstructClassNames` proof does not cover it.

Consumers: `numeric_send_mask` (INT/FLT for NumericFlow), `return_class_send_mask` (a class bit for the
exact-class flow, so `bitmap.text_size(s)` is an exact `Rect`), and `fixnum_proof_source?` (a `:fixnum` result
is a small Integer, so a native-direct `:int` argument or a Fixnum-tier operand loses its test). The numeric
flow now reads the exact-class flow, which reads none of the numeric pools, so `compute_return_classes` runs
right after the numeric setups instead of after the numeric fixpoint (generated code was byte-identical
before any fact was added). Both consumers wait for `@native_results_ready`, set when the exact-class table is
final, because asking mid-fixpoint would recurse into the flow still being built.

### 2. NATIVE_EXACT_DIRECT before the class-guard arms

A zero-argument name in `NATIVE_WRAPPER_ZERO_ARG_DIRECT` sent to a receiver the exact-class flow proves is
exactly one RGSS native class calls that class's entry point directly (`native_exact_direct_code`, the same
rule the later exact block applies to the other native names), instead of emitting the guard chain and its
dispatch tail first.

### 3. INSTANCE_RECEIVER: a `.singleton` definer cannot answer an instance

A `def self.width` / `class << self` method belongs to a class or module object. With
`exact_instances_singleton_free?` (no `extend`, `define_singleton_method`, `class << obj`, ... anywhere in the
build) no instance has a singleton method either. A send whose receiver the exact-class flow proves holds
only instances of classes that are not `Module`/`Class` descendants (`ClosedWorld#instance_class?`, or an
RGSS native class), plus `nil`, plus core-class bits, therefore ignores the `.singleton` owners:
`ClosedWorld#refusal` takes `instances:` and treats it like `instance_self?` (ADR 0255). It also answers the
`method_missing` question for exactly those classes (`method_missing_free?`) instead of refusing every
non-`self` receiver when any class in the world has a hook. Anything the flow cannot name (`OTHER`, a class
object, an exception, an LCF kind) gives no class list, and the site keeps its refusal.

## Consequences

Measured on the wio closed world (`scripts/bc2cpp_coverage_report.rb`'s shipped pass, master `c7ff3846` as
the base, `scripts/bc2cpp_dynamic_site_census.rb` for the send counts):

| | before | after | delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites in generated bodies | 3,224 | 3,186 | -38 |
| `bc2cpp_nomethod` sites (error raise, not dispatch) | 4,435 | 4,439 | +4 |
| `bc2cpp_slow_*` (NUMERIC_SLOW_PATH) calls in bodies | 3,542 | 3,523 | -19 |
| `NUMERIC_OPERAND_PROOF` arms | 361 | 373 | +12 |
| `operands proven Fixnum` arms | 370 | 377 | +7 |
| `NATIVE_EXACT_DIRECT` calls | 80 | 114 | +34 |
| `rgss::native_*_class()` guard arms | 2,106 | 2,034 | -72 |
| `CLOSED_WORLD kept: singleton_definer` | 167 | 130 | -37 |
| generated C++ bytes | 21,689,111 | 21,652,394 | -36,717 |

The numeric half is small and that is the honest size of it: most operands that stay unproven are
data-driven (`Game::Map#width` is a Hash lookup, `size` of an unproven receiver, `hp` of a battler) or an
ivar the class pools do not cover; only the sites whose receiver is a pooled `Bitmap`, a `Rect` from
`text_size`/`rect`, or a `Color` improved. The 130 remaining `singleton_definer` sites have a receiver the flow
cannot name (mostly `OTHER`), so only a "this is not a class object" fact from a wider receiver analysis could
clear them. One visible family is left alone here: a send to an exact project-class receiver whose *Ruby*
reader (`attr_reader`) could hand back the class set of its ivar pool instead of the name-level answer
(`@shop.index`, `msg.text_w`); that is exact-receiver propagation, not a native fact.

Three keys join `NOMETHOD_REVIEWED` (`DebugMenu#refresh_switch_or_variable -> width`,
`StatusMenu#new_contents -> height` and `-> width`). Each is the `nil` arm of a receiver the flow proves is
`nil` or one Bitmap/Window: `@left_contents.width` follows `@left_contents.clear` on the same ivar, and
`new_contents(win)` is called with `@actor_window`, `@gold_window`, ... after the scene's build step has
assigned them, so the fallback is a defensive nil dereference.

Withdrawal: a Ruby definition, alias or computed installer of the name; a second registration, `const_set`
or Ruby `Rect =`; any singleton maker (`extend`, `define_singleton_method`, `class << obj`); a prepended
module on the owner; a changed native (the audit fails first); `method_missing` for the name-level path; and
no closed world (an open-world build emits none of this).

32-bit `mrb_int`: every fact is a type claim, never a value. `:fixnum` means the native returns
`mrb_fixnum_value(..)`, which is a fixnum-tagged immediate on every target (the field it reads is an `int` or
an `mrb_int` and the tag is the same width everywhere); nothing here converts an `mrb_int` to a bignum or
back, and the generator emits no new >32-bit literal.

Checks: `scripts/bc2cpp_native_result_facts_check.rb` (audit and mutants, ClosedWorld questions, generated
code with positives and negatives for a Ruby override, a rebound `Rect`, a singleton maker, an unproven or
mixed receiver, a method_missing class and a class-object receiver), run on core-only and full-core
libmruby together with the existing numeric, class-pool, exact-receiver, closed-world and native-direct checks.
