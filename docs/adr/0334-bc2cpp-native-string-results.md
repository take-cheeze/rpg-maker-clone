# 0334. bc2cpp: join audited native String results across the core Struct alias

Date: 2026-10-04

## Status

Accepted

## Context

ADR 0333 left native `to_s` results unknown: the first audit omitted Fiber, and the core Struct Ruby alias to
native inspect and the broader foreign-source census blocked a name-wide proof. The remaining receiver-proof
follow-up needs the actual linked implementations and alias contract, rather than assuming every `to_s` returns
String. Ruby can return another class, Exception can preserve a String subclass, and OnigMatchData can return nil.

## Decision

Extend `NativeClassResults` with pinned complete source files for every supported linked native `to_s` implementation.
Join their successful results with all compiled Ruby return masks through the existing least fixpoint. Calls and
method lookup remain intact. A Ruby `to_s` returning another class widens the join and prevents exact String dispatch.
`BC2CPP_NATIVE_STRING_RESULTS=0` withdraws this new proof; the existing native-class-results switch also disables it.

### Native contracts

| Native source / owner | Result discipline |
| --- | --- |
| String | Exact String returns itself; subclasses duplicate to a base String. |
| Array, Hash, Struct | Build a fresh base String and append inspected fields. Callback results cannot replace the allocated result. |
| Integer, Float, BigInt | Numeric conversion allocates a String; the BigInt delegate is audited even when no registration in its file spells `to_s`. |
| Symbol | The symbol-string helper returns a String. |
| Object / nil / booleans / Kernel | Literal or formatted Strings. |
| Class / Module | Class-name helper returns a duplicated String or allocates an anonymous name. |
| Exception | Returns a String message that may retain its subclass. |
| Range | Builds the endpoint representation into a String. |
| Proc, Method, Time | Allocate formatted Strings. |
| Fiber | Allocates a String buffer and appends class, location and state. |
| RGSS Rect, Color, Tone | Format into a buffer and construct a String. |
| OnigRegexp / OnigMatchData | Regexp allocates a String; MatchData's substring may be nil after the matched String changes. |

Require `ClosedWorld#native_subclass_free?(['String'])` for the name-wide exact-class proof. This covers Exception's
preserved message class as well as compiled Ruby results. When native Onig is linked, the native result is
**String or nil**. Its normal interpreted Ruby integration contains runtime installers, which independently withdraw
the proof; the native-only fixture checks the nullable flow without bypassing that integration refusal.

Full-source pins cover registration, helpers, conditionals and macros. Both pristine and project-patched versions
of symbol, error, class, kernel and Proc sources are audited where patches change unrelated implementation details.
A changed byte or unsupported linked source withdraws the fact. The numeric file additionally requires the pinned
BigInt helper. No claim is made for an unmodelled native extension's `to_s`.

### Core Struct alias boundary

Only the exact pinned `mruby-struct/mrblib/struct.rb` alias `to_s inspect` is admitted outside the compiled registry.
Its inspect lookup must retain the unique pinned Struct native `mrb_struct_to_s` registration. Ruby replacements,
alias replacements, unknown installers, prepends/mixins and opaque or duplicate native registrations withdraw it.
Any compiled `to_s` alias must also be that exact pinned alias to inspect. An arbitrary alias is not a bytecode
body the return table models and stays refused.

`ClosedWorld#native_return_sources_visible?` accepts only explicitly audited outside Ruby paths and retains the
existing global, method_missing and unknown-definition refusal checks. The caller supplies only matching pinned
Struct alias paths. This distinguishes linked Ruby from the broader unlinked foreign-source census without
admitting arbitrary interpreted definitions. Other method names retain their previous admission rules.

### Measurement

Full Wio coverage on master `98914faf`, switch off versus on on this tree:

| Measure | Off | On | Change |
| --- | ---: | ---: | ---: |
| Cached by-name sends / with-block sites | 2,865 | 2,845 | -20 |
| Class ivar pools | 188 | 189 | +1 |
| Class argument pools | 120 | 136 | +16 |
| NILABLE_RECEIVER sites | 918 | 921 | +3 |
| INDEX_EXACT arms | 1,025 | 1,025 | 0 |

The reviewed no-method fallback list remains unchanged: 2,931 keys / 4,186 sites pass the full Wio gate.
With the switch off, shipped C++ is byte-identical to master (SHA-256
`000c5eae62558741567ce07e4fb0e05c11eebd807d59ad1bc2d2c07274d96444`).
ADRs 0332–0334 together remove 79 cached sites, from 2,924 to 2,845. The count is a generated-code measure,
not a runtime-speed claim. Three extra nil-receiver helpers preserve possible errors.

## Consequences

String results now carry their class through callers, arguments and stores. Source pin maintenance is deliberately
conservative: re-audit changed contracts and rerun withdrawal/mutation checks before refreshing a digest.
Native setter values (`contents=` / `bitmap=`), dynamic caller completeness and unknown collection elements remain
independent future proofs; this change does not constrain setter inputs or assume element classes.

`scripts/bc2cpp_native_string_results_check.rb` audits every source pin and the BigInt delegate, verifies nullable
regexp results, and checks generated withdrawal for aliases, Struct replacements, linked foreign/native definitions,
installers, singleton creation and open worlds. Compiled/interpreted parity runs on full-core, core-only and 32-bit
mruby for String results, a Ruby return of another class, a String subclass and the kill switch. The C harness supplies a >32-bit
value through numeric-string conversion to exercise BigInt in the width build independently of literal emission.
The mutation check kills eleven mutants plus an unmodified control. CI runs these in `call-facts` and the 32-bit
runtime leg in `bc2cpp-width (int32)` with `NSR_FULL_ONLY=1` to avoid discovering a separate 64-bit host core library.
