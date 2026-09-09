# 117. Strip MRB_DEBUG (mruby core's C-level assertions) from the wio build

Date: 2026-09-09

## Status

Accepted

## Context

Asked whether "debug messages" could be omitted for wio specifically.
ADR 115 already stripped mrbc's own `-g` (Ruby-level line-number/local-
variable debug tables embedded in compiled bytecode), but `enable_debug`
(called by wio's `CrossBuild` block) sets three different things, only one
of which ADR 115 touched:

- `-g3` on cc/cxx: native DWARF debug info. Harmless -- ELF debug sections
  sit outside every `PT_LOAD` segment, never mapped into flash or RAM at
  runtime (same reasoning docs/adr/0047-psp-memory-budget.md already gave
  for PSP). Left alone.
- `-g` on mrbc: fixed by ADR 115.
- `MRB_DEBUG`, a C preprocessor define on every cc/cxx compile. Not
  DWARF, and not mrbc's own flag -- a third, separate thing, and the one
  that turns out to still cost real flash.

`mruby.h` gates `mrb_assert(p)` on `MRB_DEBUG`: defined, it expands to a
real `assert(p)` (`#include <assert.h>`); undefined, a no-op. `mrb_assert`
is used roughly 100 times across mruby's own `src/` alone (31 in `vm.c`,
14 in `gc.c`, 13 in `class.c`, ... not counting mrbgems) -- every one of
those, with `MRB_DEBUG` defined, compiles to a real conditional branch plus
a string literal holding the assertion's source text and file/line, to
call `abort()` through if the VM or GC ever hits a state that should be
impossible. Nothing PSP's own build (or android/emscripten) removes this
either -- `enable_debug` sets it uniformly and nothing downstream had
touched it before this.

## Decision

`t.defines.delete('MRB_DEBUG')` alongside the existing wio-only cc/cxx
tuning (`-Os`, `-ffunction-sections`, `MRB_HEAP_PAGE_SIZE=256`, ...), scoped
the same way -- wio only, not PSP/android/emscripten. A failed `mrb_assert`
would only ever fire on an actual bug in mruby's own VM/GC/class
implementation (not a game's Ruby, not this project's own RGSS/rpg2k code,
which raises real `mrb_raise`/exceptions instead, unaffected by this), and
this firmware has no attached debugger and no serial console wired up to
read an `abort()`'s message even if one fired -- the check buys nothing a
production device could act on. This is a different mechanism than ADR
115's mrbc fix (a C preprocessor define read by `#include <mruby.h>`, not
an mrbc compile-time flag baked into bytecode), so it needed its own,
separate change.

### What was verified

A real relink, `env:wio_rgss_boot`, on top of ADR 116's state:

| state | FLASH overflow |
| --- | --- |
| ADR 116 (boot-time full GC) | 993,676 |
| + `MRB_DEBUG` stripped | **975,984** |

**17,692 bytes of flash**, RAM unchanged (`mrb_assert`'s failure branches
carry no static data, only code and string-literal text -- confirmed via
`.data`/`.bss` sizes matching exactly before and after). Also confirmed
directly: `strings` on the rebuilt `libmruby.a` finds zero `assert(`
occurrences, down from a real, non-zero count before this change.

## Consequences

- Wio's flash overflow drops to 975,984, a smaller but real win on top of
  ADR 115/116, closing this session's remaining known gap between `-g3`
  (harmless, correctly kept) and the two functional debug knobs
  `enable_debug` also sets (both now handled: `-g` by ADR 115, `MRB_DEBUG`
  here).
- If mruby's own VM/GC ever hits a genuine internal-consistency bug on this
  board, it now fails silently (undefined behavior past that point) rather
  than a clean `abort()` -- an accepted tradeoff on a device that could not
  report the assertion failure to anyone regardless, matching every other
  target this session already treats production flash/RAM budgets as
  overriding non-actionable diagnostics for (ADR 115's own bytecode debug
  tables, chief among them).
- PSP/android/emscripten are untouched -- this fix is scoped to wio's own
  `CrossBuild` block only, the same scoping ADR 112/113/114/116 already
  used for wio-specific decisions.
