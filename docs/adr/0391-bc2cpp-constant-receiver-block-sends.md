# 0391. bc2cpp: constant-receiver block sends (Array.new inlined, Profiler inlining widened)

Date: 2026-10-10

## Status

Accepted

## Context

Classifying the 51 block sends that still ended in a by-name `mrb_funcall_with_block` with no class guard
(`BLOCK_FALLBACK ... dynamic dispatch`, measured with `scripts/bc2cpp_block_send_report.rb` on master `5ddf1d98`):

| callee | sites | what keeps it dynamic |
| --- | ---: | --- |
| `RGSS::Profiler.section` / `.frame` | 12 | 9 sit in `rescue` ranges (ADR 0376 kept the profiler pass out of try bodies); `frame` fails `profiler_result_lookup_safe?` because `Game::EventGraphic.frame` exists |
| `Array.new(n) { }` | 12 | native `new`/`initialize` with a block: no compiled target exists, so only an inlined loop removes the send |
| `File.open` | 5 | the callee is hidden core Ruby (`IO.open`, name shared with natives): not a registry target |
| `Kernel#loop` | 7 | hidden core Ruby again; 3 `break`, 3 `return` through the block |
| `reduce` 5, `index` 3, `each_line`/`each_char` 2, `_rgss_native_sort` 2 | 12 | receiver class not proven (results of sends) |

The 32 `EXPLICIT_BLOCK_ARG` sites are `select(&:sym)`-style on unproven receivers or `self` inside Enumerable/Array/String
bodies compiled once for every receiver class; no sound direct call exists for them and they are unchanged.

## Decision

1. **Array.new(n) { |i| }** (`ARRAY_NEW_BLOCK`, `codegen_array_new_inline.rb`): an inline pass in the shape of the `map`
   inliner. It reproduces `mrb_ary_init`: `size = mrb_as_int(arg)` (same conversion, same TypeError), a size <= 0 runs the
   block zero times and answers `[]`, `mrb_ary_new_capa` raises the same "array size too big", slot i gets the block value
   (a push: the array is unreachable until the call returns), `break v` is the call's value, `next v` the slot's value,
   `return` is a plain C++ return. Gate, each clause a counted refusal reason printed as the
   "Array.new block inlining" report: the receiver register is the constant `Array` on every path (straight-line walk
   skipping the BLOCK), resolved with no lexically nested `Array`, never rebound; `new`/`allocate` cannot have been
   replaced (`standard_constructor_lookup?`, `exact_constructor_chain?`, no registry definition on Array, Object,
   BasicObject, Class, Module, Kernel or their singletons, no prepend/unresolved mixin there); `Array#initialize` is
   mruby's own (no outside Ruby definer or installer, no registry or hidden core definition on Array, no prepend on Array,
   no native source other than `array.c` that spells `initialize` and names the Array class); one argument and a 0/1
   parameter block that does not read the frame's block. The arena is not released per pass, as in the other inliners: the
   body may write a level-0 local nothing else roots. `symbol_installed_destinations` counts only the name an
   `alias_method` installs (Window's `alias_method :_rgss1_initialize, :initialize` does not touch Array).
   `BC2CPP_ARRAY_NEW_INLINE=0` keeps the call.
2. **Profiler pass in rescue try bodies** (`rescue_try_pass?`). ADR 0376 excluded it believing a raise skips an end call
   the block call would make. `prof_section`/`prof_frame` call `profiler_section_end`/`profiler_frame_end` after
   `mrb_yield_argv` returns with no unwinding guard, so a raise skips the end call there exactly as in the inlined code; the
   behavioural half of `scripts/bc2cpp_profiler_scope_check.rb` records begin/end sequences of the natives and of the
   inlined code for returning and raising bodies and requires them equal. `BC2CPP_RESCUE_PROFILER_INLINE=0` restores the
   exclusion.
3. **Profiler name lookup scoped to the module** (`profiler_name_unshadowed?`): both callers prove the receiver is the
   constant `RGSS::Profiler`, whose lookup finds its own native singleton method first, so a Ruby `frame` on other classes
   does not matter; a definition whose owner's last segment is `Profiler` (any spelling) still stops it.
   `BC2CPP_PROFILER_NAME_SCOPED=0` restores "every definition of the name is native".
4. **Bug fixed on the way**: a section nested in another inlined section took its function name from its block-relative
   address, so a `frame` at 13 holding a `section` at 13 defined one function twice (found by the new compile-and-run
   check). Nested names now carry the irep label.

## Not done (refused or out of reach)

`File.open`, `Kernel#loop`, `reduce`, `index`: the target is hidden core Ruby or the receiver class is unproven, and a
direct call would need a hidden-core call-with-block path; `loop` additionally needs StopIteration handling and
`break`/`return` through a rescue. The 32 explicit-block sends need a receiver class proof, not a block rule.

## Consequences

Shipped pass (wio closed world), master vs this change: dynamic `BLOCK_FALLBACK` 51 -> 30 (section/frame 12 -> 0,
`new` 12 -> 3), `mrb_funcall_with_block` 408 -> 387, `mrb_funcall*` 418 -> 397, `mrb_proc_new_cfunc_with_env` 441 -> 420,
`bc2cpp_send(` 2082 -> 2085 (nested bodies), 0 `#error`. Checks: `bc2cpp_array_new_block_check.rb`,
`bc2cpp_profiler_scope_check.rb`, mutants in `bc2cpp_block_direct_mutation_check.rb`.
