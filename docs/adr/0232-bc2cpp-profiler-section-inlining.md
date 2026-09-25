# 0232: Inline RGSS::Profiler section/frame blocks

Date: 2026-09-25

## Status

Accepted

## Context

`RGSS::Profiler.section("name") { ... }` and `Profiler.frame { ... }` are the
two remaining hot-only block fallbacks in `mruby-rpg2k` that are not collection
loops. They are the only remaining *block-taking native method* on the hot
path: every other one is an Array/Hash/Range iteration, which the loop
recognizers already lower.

They were the largest remaining cluster by count. In the real Wio hot-only
`mruby-rpg2k` output, 26 of 56 `BLOCK_FALLBACK` markers were `:section` or
`:frame` — 46% of all block fallbacks in the gem — concentrated in
`Scene::Map#initialize` (10), `#render` (6), `#draw_map_animation` (5),
`Scene::Map#update` (3), `RPG2k#main_loop` (2, nested inside its `frame`),
plus `start_new_game`/`continue_game` and `perform_teleport`.

Each one costs an `mrb_proc_new_cfunc_with_env` RProc, a
`mrb_funcall_with_block` by-name dispatch, a `try`/`catch` around that dispatch,
and a standalone cfunc function — all to reach a native function whose whole job
is "time the block, return its value".

## Decision

Add `PROFILER_SECTION_SUPPORT`: a recognizer and emitter pair, in the same
`INLINE_LOOP_PASSES` shape as the collection inliners, that lowers these sites
to a direct call around the native timing primitives.

**The timing is not reimplemented.** `profiler_section_begin()`,
`profiler_section_end(name, start)`, `profiler_frame_begin()` and
`profiler_frame_end()` are this project's own public C++ API
(`include/profiler.hxx`). They already own the enabled test, the clock read, the
per-name aggregation and the Chrome-trace write, and are documented no-ops when
profiling is off. So `prof_section`'s own
`if (!g_enabled) return mrb_yield_argv(...)` fast path collapses into calling
the two primitives — the same trade the shipping code already makes in
`mruby-rgss/src/lib.cxx`, where `ProfilerScope` times `gfx.zorder` / `gfx.lvgl`
/ `gfx.invalidate` in the same per-frame hot path.

**The body becomes its own `static` function, called directly.** This is what
makes the change a removal rather than a relocation: versus `BLOCK_FALLBACK`
there is no RProc, no by-name dispatch, and no `try`/`catch`. It is also the
only shape that compiles. A method body's own `goto` for its ENTER /
optional-argument dispatch (e.g. `goto L19` in `Scene::Map#initialize`) jumps
forward across whatever the straight-line body declares, and C++ forbids a jump
that crosses an initialization — so a braced in-place body, or flat emission,
both fail to compile. A separate function has its own frame and its own label
namespace, exactly like the block-fallback cfuncs it replaces.

**Gate.** A site is admitted only when all of these hold, and otherwise keeps
today's `BLOCK_FALLBACK` unchanged:

- the shape is `BLOCK` immediately followed by a block-carrying `SENDB`;
- the name is exactly `:section` (n=1) or `:frame` (n=0);
- the receiver is the literal constant path `RGSS::Profiler` — the
  `GETCONST RGSS` + `GETMCNST (R<r>)::Profiler` pair immediately before the
  BLOCK (one `STRING` earlier for `:section`, whose name argument is written in
  between). A local alias, a rebased constant, or a different receiver
  answering `section` is not matched;
- the block register is the one after the arguments (`dest+1` for `frame`,
  `dest+2` for `section`), i.e. the VM's real `OP_SENDB` layout;
- `:section`'s name is a **String pool literal**, which is what lets the emitter
  pass a static `const char*` — the primitive copies the name into its
  aggregation key during the call, so a static literal is exactly what the
  header asks for, and it also drops the name-register `GETIDX` and the
  `mrb_string_value_cstr` the fallback paid on every call. A computed name is
  declined rather than approximated;
- the block is mandatory-arity zero, its captures are modellable, and neither it
  nor anything nested in it contains `break`.

A level-0 capture arrives as a by-value parameter named
`bc2cpp_prof_up_<i>` and is bound into the body's frame, because a capture
index can fall inside the block's own `r0..r<nregs-1>` range and would
otherwise be redeclared or clobbered by that frame's nil-initializer.

The generated file includes `profiler.hxx` only when a body was actually
inlined, so a gem with no such site keeps byte-identical output.

## Consequences

In the real Wio hot-only `mruby-rpg2k` output: 26 → 5 `:section`/`:frame`
fallbacks, 56 → 35 block fallbacks in total, `mrb_funcall_with_block` 58 → 37,
`mrb_proc_new_cfunc` 57 → 36. A same-flags `-Os` object comparison shows
**5,901 bytes less `.text`** and 18,928 bytes less total object size, from 21
inlined sites.

The 5 that remain are all inside `Scene::Map#perform_teleport`'s `rescue`
ranges, where no inline pass runs by design (`RESCUE_INLINE_BLOCK_FIX`: a loop
registered inside a rescue range would be emitted on the exception-only path,
with its receiver register holding whatever that path left). Reaching them means
extending inline passes to rescue try bodies, which is a separate change with
its own register-capture obligations.

`scripts/bc2cpp_profiler_section_check.rb` covers the codegen shape (primitives
inlined, static literal name, no RProc, refusal of a computed name and of
`break`) and, against real `libmruby_core.a` with recording stubs, the semantics
that matter: the body's value is what the method returns, `next` works, `frame`
brackets the body, each section closes with its own literal name, and the
disabled-profiling path still runs the body and returns its value.

One behavior is deliberately inherited rather than reimplemented: a `return`
inside the body returns from the enclosing method, so `prof_section`'s
`mrb_yield_argv` never reaches its own `profiler_section_end` either. A body
like that was already an unsupported case (the enclosing method's `RETURN_BLK`
blocks the method from compiling), so no site changes.
