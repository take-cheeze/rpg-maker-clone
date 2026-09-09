# 116. Force a full GC pass right after boot-time class/method loading, before the main loop starts

Date: 2026-09-09

## Status

Accepted

## Context

Two related questions prompted this: whether unused Ruby methods could be
omitted from the build, and whether mruby could get an "unload" feature
that precomputes class/method loading right before the main routine
starts, freeing whatever that loading needed once it's done.

**The second idea's premise already holds, and its literal form doesn't
apply to a bytecode interpreter.** `app/wio/src/wio_rgss_boot_main.cxx`'s
`setup()` (Arduino's boot-once entry point, which always runs to
completion before `loop()`, the main routine, is ever called) already does
all class/method registration up front: `mrb_open_core()` +
`rpg_maker_init_shared_gems` + `rpg_maker_init_rpg2k_gem`, the same
two-step the desktop build's `main.cxx` uses. There is no point during
`loop()` where more Ruby gets loaded. But "unload the compiled Ruby once
classes/methods are registered" isn't sound for what this project ships:
unlike a JIT that compiles method bodies to native code and can discard the
source/IR afterward, mruby's `mrb_proc` for every method just points at its
`mrb_irep` (the compiled bytecode tree) directly, and the VM interprets
that same tree fresh on every single call for the program's entire
lifetime -- there is no later point where the bytecode becomes safe to
free, "loaded" or not; it *is* the method body.

**What genuinely is reclaimable**: `mrb_load_irep` (what
`rpg_maker_init_*_gem` calls under the hood, once per gem) allocates real
GC-tracked scaffolding while walking each IREP tree -- `RProc`/`Array`
wrapper objects that back the loading process itself, not retained by the
classes/methods that come out the other end. That garbage would otherwise
just sit on the heap until mruby's own incremental GC happens to cross its
size threshold sometime during normal play, rather than being reclaimed
promptly.

**The first idea (omit unused Ruby methods) does not have a safe answer**,
unlike every C++-level dead-code trim this session already made (ADR
109-115), all of which relied on the *linker* proving a symbol
unreachable -- sound because C++ call sites are statically resolved.
Ruby's method dispatch is late-bound: `mruby-rpg2k/mrblib/game.rb` alone
has dozens of `receiver.send(name)`/`receiver.send(field)` call sites
(stat flags, database field accessors) where `name`/`field` is a symbol
computed from *game data* (a project's own `.ldb`/`.lmt` database), not
visible anywhere in the Ruby source. A method that looks unreferenced by
grepping literal call sites can still be the exact method one of these
`send`s reaches for a specific game's data -- there is no static call graph
to prove otherwise, and this bring-up firmware loads no real game data yet
to build a *dynamic* (coverage-based) one from either. Attempting this
without either would risk silently deleting a method some real game's
event data calls by name, the one class of bug this whole series has taken
real care never to introduce.

## Decision

Added one `mrb_full_gc(M)` call in `wio_rgss_boot_main.cxx`'s `setup()`,
right after `rpg_maker_init_rpg2k_gem` succeeds and before anything else
runs (including the status-screen LVGL widgets `setup()` itself still
creates after that point) -- a one-time boot cost, not a per-frame one,
that sweeps whatever the loading step's own scaffolding left behind before
`loop()` takes over. Left `unused Ruby methods` alone entirely: no
build-time change, pending either real game-data-driven coverage data or a
different, sound static-analysis approach neither of which exists today.

### What was verified

A real relink, `env:wio_rgss_boot`: compiles and links cleanly (`mrb_full_gc`
is already part of mruby's always-linked GC subsystem, called nowhere
explicitly before this), and the flash overflow is **unchanged**,
993,676 bytes -- this call adds no new code the linker wasn't already
keeping for GC's own normal operation during play, only a single new call
site to it.

## Consequences

- Boot-time GC scaffolding is reclaimed deterministically before the main
  loop starts, rather than left for the VM's own lazy threshold to catch
  whenever that next happens to trigger during play.
- Freed GC pages return to the same shared newlib heap LVGL's own
  allocations draw from since ADR 112 (mruby's page-based heap already
  calls plain `free()` for pages that become fully empty after a sweep,
  independent of the separate, still-unused `MRB_USE_MALLOC_TRIM` build
  option) -- one more small argument for that ADR's own shared-heap
  decision, not a new one.
- "Omit unused Ruby methods" remains an open question, explicitly not
  attempted here: the real path to it is a coverage-based approach once
  this port can actually load and play a real game, not static analysis
  against source that already shows real `send`-with-dynamic-symbol
  dispatch this early.
