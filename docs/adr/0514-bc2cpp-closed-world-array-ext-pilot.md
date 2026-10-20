# 0514. bc2cpp: a closed-world pilot for mruby-array-ext

Date: 2026-10-19

## Status

Proposed

## Context

The wio closed world (`build_config.rb`, `bc2cpp_closed_world_outside_srcs` in `tools/bc2cpp/compiled_gems.rb`)
compiles four gems (`mruby-core`, `mruby-lcf`, `mruby-rgss`, `mruby-rpg2k`). Twenty-two gems are not compiled. Their
C and C++ sources, and for nineteen of them their `mrblib` Ruby too, are outside the closed world. Outside code can
call a method name without the closed world seeing the call, so every parameter whose callers may include a name
reachable from outside is refused a declared or inferred type (`rbs_param_check.rb`, TC1014). The root-typing
measurement on `claude/const-types-folding-w7k2` found 79 of 405 refused poly-name parameters blocked by outside
reachability; most of the rest are blocked by untraced arguments, which this ADR does not change.

Two prerequisites follow from how the analysis works:

- Removing a gem's Ruby from the outside set is only sound when that gem's own methods are in the program the analysis
  sees. The `BC2CPP_CLOSED_WORLD_GEMS` list (`mruby-rpg2k`, `mruby-lcf`, `mruby-rgss`) does this for gems that have a
  `*-compiled` counterpart. Adding a gem to that list without compiling its IR would hide its callers and is unsound.
- A gem's C sources still contribute outside name tokens (`outside_call_names`). Making them directly callable means
  the generator emits a direct C call for a native method whose signature it knows, instead of a by-name dispatch.
  `native_direct.rb` and `native_core_direct.rb` already do this for some core and RGSS natives.

## Decision

Pilot the closed world on one gem: `mruby-array-ext`. The pilot is the smallest change that satisfies the prerequisites:

1. Add a `mruby-array-ext-compiled` mrbgem in the same shape as the existing `*-compiled` gems, so its IR enters the
   program through the compiled-gem path.
2. Add `mruby-array-ext` to the closed-world gem list only in that same change, so its Ruby stops being outside.
3. Route its native `Array` methods through the existing direct-call tables where the signature is known. Methods
   without a known signature stay by-name and stay outside.
4. Measure before and after on the same tree: the outside name-token set, the TC1014 refusals, and the untyped
   parameter reasons. Also the generated-code diff for the wio shipped pass.

The pilot is accepted only if the measured outside set shrinks and every changed generated call site is explained.
Otherwise the decision is withdrawn and this ADR is marked Superseded.

## Consequences

- Generated C++ grows by the compiled `Array` extension methods. The diff is reviewed against the census before merge.
- The native C of `mruby-array-ext` remains outside until the direct-call tables cover every method it defines. The
  pilot does not claim the native side is closed.
- The same recipe applies to the other nineteen outside gems. Each gem is a separate pilot with its own measurement.

## Not decided

- Whether the whole dependency chain of the wio build should be compiled. The pilot measures one gem first.
- How the C sources of mruby core and the extension gems should be modelled, beyond the direct-call tables.
