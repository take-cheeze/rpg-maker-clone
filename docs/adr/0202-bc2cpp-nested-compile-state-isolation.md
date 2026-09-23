# 0202. bc2cpp nested compiles run against fresh per-method state

Date: 2026-09-23

## Status

Accepted

## Context

`compiles_clean?` answers "does this callee compile without `#error`?" by
running `compile_method` on the callee. It is called while another method is
still being compiled, from a devirtualization gate inside that method's body.
`compile_method` and the block emitters keep their per-method context in
instance variables: `@elem_class_hint`, `@block_hash_capture_hints`,
`@block_fallback_upvars`, `@block_fallback_active`, `@blk_param_name`,
`@blk_param_level`, `@inline_nested`, `@inline_nested_pre`,
`@suppress_native_expression_send`, `@runtime_installed_names`,
`@ensure_except_remaps` and `@self_class_unknown`. The nested compile started with the caller's values.
It then reset several of them to nil or false when it finished, so the rest of
the caller compiled without them.

A caller that probes a callee inside a block-fallback body and then reads an
upvar or forwards a `yield` in the same body loses `@block_fallback_upvars` or
`@blk_param_name`. The body gets `#error`, the block falls back to an unhandled
`BLOCK`, and the method is memoized as unclean. Ten methods that compile clean
on their own were memoized unclean this way, including
`RPG2k::Scene::Map#pages_changed?`, `Game::Battle#swing` and
`Game::State#to_lsd`. Their 13 call sites stayed POLY, and 18 `Game::State`
ivars were not embedded because some of their readers were counted as
uncompiled.

Other effects of the same leak can produce wrong code, not just slower code.
A `break` in the block body after the probe compiles as a plain `return`,
because `@block_fallback_active` has been cleared. A cleared
`@runtime_installed_names` lets a name the caller installs at runtime be
devirtualized. A cleared `@ensure_except_remaps` drops the ensure jump remap.
`@self_class_unknown` is restored by its own `ensure`, but a probe started
inside a runtime-def/EXEC body inherited it and compiled the callee as if its
`self` class were unknown. None of these appears in today's output, but a small program reproduces the
`break` case.

## Decision

`CodeGen::METHOD_COMPILE_STATE` lists those ivars with their top-level values.
`compiles_clean?` runs the nested `compile_method` inside
`with_fresh_method_state`. That helper sets every listed ivar to its top-level
value and restores the caller's values afterwards, including after an
exception. So the callee compiles exactly as it would at top level, and the
caller continues with its own state.

The other ivars that CodeGen writes after construction are not per-method
state. They are memo caches of pure functions (`@clean_cache`,
`@fixnum_proof_ctx`, `@own_upvar_written_regs`, `@symbol_installed_names`,
...), file-scope output accumulators (`@const_site_cache`,
`@owner_class_cache`, `@native_construct_used`, ...), proofs finished in the
constructor, or `compile_all`'s owner filters. A probe can add accumulator
entries for a method this gem does not emit. That only adds unused helpers,
and it already happened before this change.
`scripts/bc2cpp_nested_compile_state_check.rb` fails when a new ivar is written
outside the constructor without being classified. It also compiles three
fixture methods with the callee probed first and not probed first, and requires
identical code with no `#error` and a `break` that still throws. The old code
fails 8 of its assertions.

### Game::State embedding stays as it was

With correct memos, `drop_unsafe_embeddings` would embed 18 more `Game::State`
ivars (`map_id`, `x`, `y`, `direction`, the access flags, the battle counters,
`font_id`, `atb_mode`). The new `BC2CPP_EMBED_IVAR_LIMITS`
(`compiled_gems.rb`) keeps `Game::State` at the three ivars it already
embedded. Lifting the cap is left to a separate change.

The static evidence is good. Since the IVAR_ACCESS helper (#1896/#1897),
accessor devirtualization calls the synthesized struct accessor, and without
the cap `scripts/bc2cpp_embedded_ivar_access_check.rb` finds 0 iv_tbl accesses
to the 193 embedded ivars. `scripts/bc2cpp_wired_embedding_check.rb` also
reports all 73 `Game::State` entry points installed, and `#initialize`
allocates the struct. What is not covered is the type of values written from
outside compiled code. `IvarLayout` proves only `SETIV` sites, and callers set
the new ivars through `state.x = ...` in many places, for example
`Game::State.load` and `.from_lsd`. A value that is not an Integer or a
boolean now raises `TypeError` from the synthesized writer instead of being
stored. That needs a real save/load run before the cap is lifted.

## Consequences

`scripts/bc2cpp_coverage_report.rb`: POLY sites go from 3245 to 3232. Compiled
entry points (2369), embeddings and every other count are unchanged. Without
the cap the fix would also give 2404 entry points, 112 synthesized accessors,
72 Fixnum-returning methods and 3229 POLY sites. In the
generated C++, the only semantic change is those 13 sites. They become direct
calls (`MONO`, or `MONO_EMBED_GUARD` with its class guard) to methods that the
same run already compiles and registers. The per-file const-site and
owner-class caches are listed in a different order. Their content is the same.

The memo now matches a top-level compile of every method except
`RPG2k3::Scene::Battle#update`. That method is part of a mutually recursive
cycle through `super`, and the recursion guard reports false for it (the safe
direction). The same thing happened before this change. Running `compile_all`
forward, reversed or shuffled gives identical memos and code, both before and
after the change. The constructor fills the memo, so what the memo depended on
was whether a method was compiled nested or at top level, and that dependence
is now gone.
