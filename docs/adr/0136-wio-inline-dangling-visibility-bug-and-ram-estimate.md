# 136. Two real crash bugs from ADR 131's own inlining, and how much RAM wio_rgss_boot actually needs

Date: 2026-09-10

## Status

Accepted

## Context

Asked to widen RAM (on top of docs/adr/0135's widened flash) to measure how
much RAM `wio_rgss_boot` actually needs to finish booting, the very first
attempt -- now that the ADR 135 vector-table bug was fixed and the RAM
ceiling was no longer the immediate wall -- hit a *different* real crash:
`RPG2k::Scene::Map`'s own class body calls `public :try_open_debug_menu,
...`, and `mrb_mod_public` raises `NoMethodError` because that method does
not exist. Not a memory problem at all.

### Root cause: ADR 131's AST-based inlining missed a real reference class

`strip_wio_inline_helpers.rb` (docs/adr/0131) inlines a hand-picked set of
methods into their one real *engine* call site, on the premise that each
candidate has exactly one caller within the files this build-time step
rewrites. `try_open_debug_menu`'s own definition and its one in-class bare
call (`scene/map.rb`) were correctly found and rewritten -- but
`scene/map.rb` *also* contains `public :play_battle_bgm, ...,
:try_open_debug_menu, ...` (a visibility declaration, needed so
`Scene::Battle`/`RPG2k3::Scene::Battle` can call `@map.try_open_debug_menu`
across objects) a few thousand lines later. `public :symbol` is a real
method call, evaluated at class-definition time, that looks the named
method up right then and raises if it is missing -- but it is a bare
symbol literal, not `.method_name` call syntax, and the tool's own
caller-count analysis evidently never treated it as a reference at all.

The tool's own safety net (the header comment cites "a real mrbc compile"
as the verification step, matching ADR 129's original methodology) could
never have caught this class of bug: `mrbc` only checks Ruby *syntax* --
`public :anything` is syntactically valid regardless of whether the method
exists -- so the failure is invisible until the bytecode actually
*executes*, which nothing in this project's build or CI did before this
session started actually booting firmware under Renode.

**Searched for every other instance of the same pattern**: cross-referenced
all 116 inlined candidate names against every `public`/`private`/
`protected :symbol,...` declaration in `mruby-rpg2k/mrblib` (not just
ordinary `.method_name` calls, which the substitution table already
handles correctly). Found exactly one more: `rebuild_chipset`, referenced
by a bare `public :rebuild_chipset` in `scene/map.rb` for
`chipset_editor.rb`'s benefit (a debug tool, itself excluded from the wio
build by `mrbgem.rake` -- `try_open_debug_menu`'s own external callers,
`scene/battle.rb`/`scene/battle_rpg2k3.rb`, are wio-excluded too, for an
unrelated reason, docs/adr/0107). Confirmed empirically as well as by
search: after reverting both, a full clean boot run reaches this ADR's own
success breakpoint with no further abort anywhere in between.

### How much RAM wio_rgss_boot actually needs

With both bugs fixed and RAM widened enough to not hit the docs/adr/0135
wall, `setup()` now runs to real completion under Renode (`mrb_open_core`,
both gem-init calls, `mrb_full_gc(M)`, reaching the `g_result =
kResultPass;` line). Measured via GDB at that point:

- `.data`/`.bss`: 33,248 bytes (RAM origin to `__end__`)
- Heap growth (`_sbrk`'s own `heap_end`, a monotonic high-water mark --
  `mrb_full_gc`'s own sweep reclaims logical objects for reuse *within* the
  arena but never lowers this number, so sampling it after the GC still
  reports the true peak reached at any point during the whole run):
  **261,400 bytes**
- Peak stack depth (found by pre-zeroing the widened stack region and
  scanning for the deepest non-zero byte after the run -- Renode's fresh
  `MappedMemory` reads as zero until written, so this is a reliable
  high-water-mark technique, the same idea as classic stack painting):
  **1,504 bytes**

**Total: 296,152 bytes to finish booting.** The real board has 196,608
bytes (192 KB) of RAM. **A shortfall of 99,544 bytes -- wio_rgss_boot, as
currently written, needs roughly 1.5x the real board's entire RAM budget
just to reach a running state, before a single frame renders or a save
loads.** The dominant cost by far is the heap growth during gem
initialization (261,400 of the 296,152 bytes) -- consistent with docs/adr/
0135's finding that constructing the RGSS/mruby-lcf/mruby-rpg2k class and
method tables as live objects is itself the real problem, not stack depth
or static data.

## Decision

**Fixed, for real, not worked around**: removed `try_open_debug_menu` and
`rebuild_chipset` from `strip_wio_inline_helpers.rb`'s candidate list
entirely (both the definition-removal and call-site-substitution entries),
restoring them as real methods in the wio build -- the simplest, lowest-risk
fix, matching exactly what every other target (and CRuby's own regression
checks, per the file's own header comment) already sees. Did not attempt
to also auto-strip the dangling `public :symbol` reference instead
(keeping the inlining and just editing the visibility list): correct in
principle, but doing it via more of the same kind of text-substitution
this exact class of bug came from was judged not worth the small
additional flash saved.

**Kept, and committed, the RAM-widened diagnostic infrastructure** the
same way docs/adr/0135 kept the flash-widened one:
`app/wio/renode/oversized_flash_and_ram_debug.ld` (FLASH widened to 2 MB,
RAM to 4 MB -- never a real hardware config) paired with
`app/wio/renode/wio_terminal_oversized_flash_and_ram.repl` (matching
`sram0` size) and a new `wio_rgss_boot_heapdbg_ram` PlatformIO environment,
not wired into a default `pio run` or CI, same convention as
`wio_rgss_boot_heapdbg`.

## What was verified

A full clean rebuild of `libmruby.a` (wio target, all 9 patches re-applied,
`strip_wio_inline_helpers.rb` with both entries removed) and a real `pio
run -e wio_rgss_boot_heapdbg_ram` link, booted twice under Renode:

- Confirmed the fix directly: GDB breakpoints on both `abort` and the
  `setup()` success line hit the *success* breakpoint cleanly, with no
  abort anywhere in the run -- `mrb_open_core`, `rpg_maker_init_shared_gems`,
  `rpg_maker_init_rpg2k_gem` (the exact call chain that used to crash on
  `try_open_debug_menu`), and `mrb_full_gc(M)` all completed.
- Reproduced the same `heap_end` value (`0x20047ef8`) across the run that
  hit the success breakpoint directly and a second run that additionally
  dumped the stack region for the high-water-mark scan -- the same
  deterministic boot path both times.

## Consequences

- **This was a real, shipping bug since ADR 131**, silently present in
  every wio build from that point until this session, never caught because
  nothing ever booted `wio_rgss_boot` far enough (blocked first by the real
  flash overflow, unrelated to CI which only compiles, then unknowingly by
  the RAM-exhaustion crash of docs/adr/0135, then finally by this one) to
  reach the code path that exercises it. **A real `mrbc` compile succeeding
  is not evidence a build's Ruby-level bytecode is safe to run** -- this
  project's build/CI story has no boot-level check at all today; ADR 135
  already flagged the same gap for linker-level correctness (`-flto`'s
  vector-table bug), and this is the same lesson one layer up the stack.
- **wio_rgss_boot cannot run on the real board today, full stop, even with
  every other bug in this session's own investigation fixed.** 296,152
  bytes needed against 196,608 available is not a close miss to trim
  toward with more per-method inlining (this whole series' usual unit of
  progress is hundreds to low thousands of bytes) -- it needs either a
  fundamentally different runtime representation for the compiled program
  (not holding every class/method as a live heap object at once, e.g. the
  SD-external-bytecode idea docs/adr/0108 never finished) or a large,
  deliberate reduction in how much of RGSS/mruby-lcf/mruby-rpg2k gets
  loaded at once. This ADR does not attempt either -- it answers "how
  much," which is what was asked.
- The two new diagnostic assets round out a small but real toolkit
  (flash-only, RAM-only... here, both together) for any future "does this
  actually run, and how far short is it" question on this target, without
  re-deriving the widening trick each time.
