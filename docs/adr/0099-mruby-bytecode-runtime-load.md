# 99. Loading mrblib bytecode from a file instead of embedding it: mechanism and real numbers

Date: 2026-09-08

## Status

Proposed

Design record and mechanism verification only. No runtime or build code
changes ship with this ADR — matching ADR 0007's own P0, this is budget
before code, because the thing this would wire into (wio's own
`libmruby.a` link) does not exist yet (see Consequences).

## Context

ADR 0007 named "place read-only bytecode... in the 4 MB external QSPI
flash" as a flash-budget lever back when it was written, still unmeasured.
Today's build always embeds mrblib bytecode as `static const` C arrays
(`mrbc -B -S`, `Command::Mrbc#run`'s default `cdump: true`) — real,
compiled machine data living in whichever section the linker puts
`static const`, which for every cross target here is internal flash. There
is a second way to get the same bytecode into a running `mrb_state`:
compile it to mruby's plain serialized RITE binary format instead (`mrbc`
with neither `-B` nor `-S`) and load that at boot with
`mrb_read_irep_file`/`mrb_load_irep_file`, from whatever storage the
board can read a file from. Nothing about the *bytecode* changes between
the two — same instructions, same pool entries, same symbol table — only
where it lives and how it gets into memory.

## What was measured

Compiled the psp/wio Ruby stack (`mruby-lcf` + `mruby-rgss` +
`mruby-rpg2k` minus ADR 0097's debug-tool files — the same set ADR 0098
leaves active there) three ways with the real `mrbc`:

| form | bytes |
| --- | --- |
| cdump (`-B -S`), `-g`, compiled to an object (x86-64 host) | 1,155,035 |
| plain RITE binary, `-g` (today's psp/wio flags, minus cdump) | 872,074 |
| plain RITE binary, `-g --remove-lv` | 843,747 |
| plain RITE binary, no `-g` | 759,086 |
| plain RITE binary, no `-g`, `--remove-lv` | 730,759 |

The cdump figure is a **host x86-64 proxy, not a device number** — same
caveat ADR 0047 Finding 5 and Finding 1 already carry: `mrb_irep`'s several
pointer fields (`iseq`, `pool`, `syms`, `reps`, `lv`, `debug_info`) are 8
bytes each here and would be 4 on the Wio's Cortex-M4 or the PSP's MIPS32,
so the real embedded number is smaller than 1,155,035 — by how much needs
an actual ARM/MIPS object, which this sandbox cannot produce (see
Consequences). What does not depend on pointer width at all: the RITE
binary is a flat serialized stream with no struct padding or pointers by
construction, so any of the four RITE-binary rows above is the real
number regardless of target architecture.

`--remove-lv` earns its own row rather than being folded into "no `-g`":
they are different flags controlling different `mrb_irep` fields (`lv`
vs. `debug_info`), and ADR 0047 Finding 5 already found that mrbc's
**cdump** path (`-S`) silently ignores `--remove-lv` — a real bug, not a
"doesn't apply here" — while the plain-binary path (`dump.c`, what this
ADR uses throughout) honors it correctly. That finding rejected
`--remove-lv` outright because `mruby-eval`/`mruby-binding` read the `lv`
table it would have stripped, and both gems were present in every build
back then. ADR 0098 removes both for psp/wio specifically (they were only
ever pulled in transitively through `mruby-rpgxp`), so the conflict is
gone for exactly these two targets — confirmed by actually compiling
`--remove-lv` output through the plain-binary path (the 843,747/730,759
rows above) and round-tripping it the same way as the debug-info rows: a
`--remove-lv`-compiled `mruby-lcf/mrblib` still loads via
`mrb_read_irep_file` and returns the identical, correct schema data
verified below. That is real evidence for `mruby-lcf` specifically, not
the full `ctest -R mruby_test` A/B ADR 0047 ran before rejecting it — a
good next step, not something this ADR calls fully proven.

Either way, the actual point of this lever was never "make the bytes
smaller" — it is moving those 730 KB-870 KB off internal flash entirely, onto
the Wio's SD card or 4 MB external QSPI, freeing that budget for what
cannot move (native code, native rodata, the LVGL/GL stacks the other
formats needed — moot now that ADR 0098 drops them for these targets too,
but true in general).

## Round-trip verification

Loading a large, real, project slice through `mrb_read_irep_file` and then
actually exercising it — not just confirming the parse doesn't crash —
against `mruby-lcf`'s genuine `mrblib/schema.rb` + `lcf.rb` (51,260 bytes,
the real two files, not a synthetic stand-in): compiled to a plain binary,
loaded into a fresh `mrb_state` (bare `mrb_open_core()` plus the real
`mrb_init_mrblib` — mruby's own Ruby-level bootstrap — object file, no
project gems), then evaluated fresh Ruby against it. It returned the
correct, real schema data — `LCF::Schema::COMMON_EVENT.size == 6`, field
11's name/enums (`:start_term`, `{3=>:auto_start, 4=>:parallel,
5=>:called}`), and the nested `DATABASE[:elements][11][:elements][31]
[:order]` array (`[:max_hp, :max_mp, :atk, :def, :int, :agi]`) — matching
`schema.rb`'s own source exactly. This proves the mechanism itself: a
large, real, deeply-nested-hash-literal-and-lambda-heavy slice of this
project's actual code round-trips through the plain RITE format with no
behavior change.

**This does not cover `mruby-rpg2k`/`mruby-rgss` together**, and that gap
is structural, not an oversight: `mruby-rgss`'s `mrblib/lib.rb` references
C-registered classes (`RGSS::Font::Color`, confirmed by reproducing the
exact `NameError: uninitialized constant RGSS::Font::Color` it raises when
loaded without them) that its own `src/lib.cxx` gem-init function defines
*before* mruby's gem system runs that file's Ruby — the same ordering
`mrb_mruby_rgss_gem_init`'s generated wrapper already guarantees today. A
from-file loader would need to reproduce that ordering by hand (call the
native registration, then `mrb_read_irep_file` the Ruby half), which is
real integration work belonging with whatever actually wires a file loader
into a boot sequence — not proven or disproven by this ADR either way.

## Consequences

- **There is nowhere to wire this in yet.** `app/psp`'s bring-up EBOOT does
  not link `libmruby.a`; the Wio firmware does not link it at all (ADR
  0007's own P1/P2 boundary). This ADR's mechanism is validated in
  isolation, ready for whichever slice actually starts the interpreter on
  either board, rather than half-wired into a boot path that does not
  exist.
- **SD/QSPI read latency at boot is not measured here and needs real
  hardware or a Renode SD model** — this sandbox has neither. Until then,
  "load 760-870 KB from an SD card once at boot" is a design claim backed
  by the mechanism working, not a timing budget.
- **The file-loading path needs a filesystem** — `app/wio/src/sd_syscalls.cxx`
  (routing newlib `_open`/`_read` to the microSD card, gated by
  `WIO_WITH_SD`) already exists for exactly this and is unused today; QSPI
  XIP (map the flash chip directly into address space, no read call at
  all) is a different, bigger lever this ADR does not attempt.
- **ADR 0098's single-format trim and this ADR compound, not compete.**
  Once psp/wio compile only `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss`, that is
  the *entire* remaining Ruby payload this lever would move off internal
  flash — there is no longer a separate "which formats" question sitting
  underneath it for these two targets.
- **`--remove-lv` is real for psp/wio now, on the plain-binary path
  specifically.** ADR 0047 Finding 5 rejected it project-wide because
  `mruby-eval`/`mruby-binding` needed the table it strips; ADR 0098
  removes both gems from psp/wio, and this ADR's own measurement
  (730,759 bytes, `--remove-lv` plus no `-g`, round-tripped correctly for
  `mruby-lcf`) is real evidence the conflict is gone there — narrower than
  Finding 5's full `ctest -R mruby_test` A/B, so worth that fuller check
  before anyone relies on it, but not a re-open-from-scratch question
  either.
