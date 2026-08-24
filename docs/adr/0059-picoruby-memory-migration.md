# 59. PicoRuby memory migration: measured, not adopted

Date: 2026-08-24

## Status

Accepted

## Context

ADR 0007 and ADR 0047 both flag mruby's own live-heap cost as a real
constraint on embedded targets (Wio Terminal's 192 KB SRAM ceiling; the
PSP's shared LVGL/mruby pool). [PicoRuby](https://github.com/picoruby/picoruby)
advertises itself as "an alternative mruby implementation" with a small
footprint (512 KB or less; 128 KB or less for its "FemtoRuby" variant), so
it was evaluated as a replacement for this project's `3rd/mruby` +
`mruby-rgss`/`mruby-lcf`/`mruby-rpg2k`/`mruby-rpgxp`/`mruby-rpgvx` stack, to
see whether switching engines would meaningfully shrink the numbers ADR 0047
measured.

### Finding 1 — PicoRuby (v4.x, the actively-developed variant) is mruby, not a different VM

Reading PicoRuby's own `include/picoruby.h` settles this directly: under
`PICORB_VM_MRUBY` (the default, and the variant PicoRuby's README says is
"mainly being developed"), `picorb_vm_init()` expands to a literal call to
`mrb_open()` — the exact same function this project already calls in
`src/main.cxx`. PicoRuby vendors `mruby/mruby` itself as a git submodule
(`mrbgems/picoruby-mruby/lib/mruby`) and builds on top of it, the same way
this project vendors it as `3rd/mruby`. There is no separate VM, object
representation, or GC underneath "PicoRuby" — it is mruby plus a curated
gem selection (`picoruby-machine`, `picoruby-vfs`, `picoruby-r2p2`,
peripheral gems, etc.) and, optionally, a bundled fixed-arena allocator
(`estalloc`, see Finding 3).

The genuinely different VM in the PicoRuby project is **FemtoRuby**
(`PICORB_VM_MRUBYC`, built on `mrubyc/mrubyc`, formerly called "PicoRuby"
before the v4.x rename) — a from-scratch, more restricted reimplementation
with its own object representation and C API (`mrbc_vm`/`mrbc_value`, not
`mrb_state`/`mrb_value`). That one was not built or measured for this ADR;
see Consequences for why.

### Finding 2 — measured live-heap cost confirms Finding 1 has real teeth

Built both from source and measured live allocator bytes immediately after
VM boot, using a method more precise than ADR 0047's RSS-based proxy: a
custom `mrb_basic_alloc_func` (mruby) / PicoRuby's own `estalloc` "used"
stat, both of which tally exactly the bytes live in the allocator rather
than host RSS (which ADR 0047 already found includes page-touch noise from
code/rodata, not just heap).

| Build | Gems | Live heap after boot |
| --- | --- | --- |
| Vanilla mruby, `build_config/default.rb` (this repo's `3rd/mruby` pin) | ~50 (array/hash/string-ext, struct, socket, pack, complex, rational, fiber, ...) | **109,812 B** (`live_bytes`, via a custom `mrb_basic_alloc_func` that tallies live-allocation bytes) |
| PicoRuby, `minimum` + `core` gembox (a custom `build_config/host-minimal.rb`, not committed) | 13 (compiler, io, task, machine, picorubyvm, time, require, sandbox, io-console, env, ...) | **123,456 B** (`estalloc_used_bytes`, exact and deterministic — arena allocator, no fragmentation) |

Vanilla mruby's baseline is *smaller* than PicoRuby's, despite having
roughly 4x the gems. This is the expected result once Finding 1 is taken
seriously: both numbers are "cost of mrb_open() plus whichever gems a build
happens to link," on the identical underlying VM. There is no engine-level
saving to find here — gem selection is the only variable, and this
project's `build_config.rb` host target already gets to choose its own gem
list independent of PicoRuby.

Then, to update ADR 0047's Finding 1 (which measured ~1.2–1.4 MB via host
RSS before/after loading `mruby-rpg2k` + `mruby-lcf` + `mruby-rgss`'s
mrblib), the same live-byte method was applied to that exact scenario:
compiled each gem's `mrblib/*.rb` individually via this repo's own
`3rd/mruby` `mrbc`, then loaded each `.mrb` sequentially into a bare
`mrb_open()`'d state instrumented with the tallying allocator (clearing
`mrb->exc` between files so one file's runtime-only dependency — a few
`RGSS::Font::Color`/`...::Color` constants not available outside the C
extension — didn't truncate the rest):

```
after_open_bytes=109812 after_load_bytes=1306793 gem_delta_bytes=1196981 peak_bytes=1395790 files=24 exceptions=4
```

**1,196,981 B (~1.17 MB) of live heap, corroborating ADR 0047's 1.2–1.4 MB
range with a cleaner method.** This is the number that matters for the
original question: essentially all of it is this project's *own*
`RGSS`/`LCF`/`RPG2k` class and method definitions, not interpreter
overhead (Finding 2's table shows the interpreter itself costs ~0.1 MB
either way). Porting those same class/method definitions to run on top of
PicoRuby's `mrb_open()` instead of this repo's `mrb_open()` would define the
same `RClass`/`RProc`/string objects on the same struct layouts and cost
essentially the same ~1.2 MB — migrating the engine does not touch the
number that motivated the question.

### Finding 3 — the one real idea PicoRuby surfaced: a bounded allocator, without switching VMs

PicoRuby's `estalloc` (`mrbgems/picoruby-machine/lib/estalloc`, MIT-licensed,
small — `est_init`/`picorb_heap_realloc`/`picorb_heap_stat`, a few hundred
lines) is a fixed-arena allocator wired in through the exact same seam this
project already uses: mruby 4.0's single global `mrb_basic_alloc_func`
(`src/main.cxx:701` today routes this through `lvallocf`/LVGL, per ADR 0047
Finding 1 — that ADR's own `src/main.cxx:638` citation has since drifted
with the file, confirmed by re-checking directly for this ADR). PicoRuby's `conf.picoruby` build helper
(`lib/picoruby/build.rb:72-103`) does nothing more exotic than call
`mrb_open_with_custom_alloc(vm_heap, HEAP_SIZE)`, which is
`picorb_heap_init(mem, bytes); return mrb_open();` — i.e. install the arena,
then call the same `mrb_open()`.

Nothing about that requires PicoRuby's build system, gem set, or VM. This
project could vendor `estalloc` directly (it has no dependency on the rest
of PicoRuby) and point `mrb_basic_alloc_func` at it, getting the bounded,
`used`/`total`/`free`/`max_free`/`frag`-instrumented heap ADR 0007's Wio
Terminal section wants ("mruby heap in a fixed pool... so the single
biggest RAM consumer is capped and measurable") without a VM migration.
ADR 0007 describes this as routing through `mrb_open_allocf`, which does
not exist on this project's current mruby 4.0 pin (confirmed: linking
against it fails — `mrb_open_allocf` was part of the pre-4.0 per-state
allocator API ADR 0047 Finding 1 says 4.0 removed); ADR 0007 predates ADR
0047's own correction on this point and should be read with that in mind.

## Decision

**Do not migrate this project's Ruby engine to PicoRuby (or FemtoRuby).**
The mruby stack already in place is not the source of the memory pressure
ADR 0007/0047 measured, and switching would cost a rewrite of the ~13,355
LOC / 18 files that call the mruby C API directly (per this ADR's own
investigation), plus reimplementing or dropping gems PicoRuby's ecosystem
doesn't carry (`mruby-onig-regexp`, `mruby-marshal`, `mruby-stringio`),
for zero measured memory benefit.

Instead, pursue the two levers Findings 2 and 3 actually point at, neither
of which requires an engine change:

- Vendor `estalloc` (or write an equivalently small fixed-arena allocator)
  behind `mrb_basic_alloc_func`, giving the Wio Terminal and PSP ports a
  bounded, instrumented mruby heap — this is a follow-up prototyping task,
  not part of this ADR.
- Treat the whole-file asset loading ADR 0007 (Finding: "the real blocker")
  and ADR 0047 (Finding 2: `RGSSAD.open`, LCF whole-file reads) already
  flagged as the actual dominant cost: a released XP/VX game's packed
  archive alone can be tens of MB, dwarfing the ~1.2 MB this ADR just
  measured for the entire RGSS/LCF/RPG2k class hierarchy by more than an
  order of magnitude. No engine choice changes that; only streaming reads
  do.

FemtoRuby (the mruby/c-based, genuinely different VM) was not built or
measured here — README-advertised as reaching 128 KB total RAM, smaller
than anything in Finding 2's table, but at the cost of a materially
different C API (`mrbc_vm`/`mrbc_value`) that `mruby-rgss`'s ~13K LOC of
`mrb_state`/`mrb_value`-based C bindings cannot compile against unmodified.
Left as a possible future option if the estalloc-in-mruby approach above
turns out not to be enough, but not pursued now: this ADR's numbers show
the interpreter was never the expensive part, so the case for FemtoRuby's
much larger compatibility break is weak until proven otherwise.

## Consequences

- Closes the "should we migrate to PicoRuby" question with measurements
  instead of priors — reusable by any future ADR that reopens it: the
  1.17–1.4 MB RGSS/LCF/RPG2k figure, the ~0.1 MB bare-interpreter figure
  either engine pays, and the `mrb_open_allocf` API-currency correction to
  ADR 0007 are now recorded here rather than needing to be re-derived.
- No runtime or build code changes ship with this ADR — the `build_config/
  host-minimal.rb` file used for Finding 2's PicoRuby measurement was
  scratch and is not part of this repo's tree.
- Follow-up work this ADR motivates but does not do: prototyping
  `estalloc` (or equivalent) behind `mrb_basic_alloc_func`, and continuing
  ADR 0007/0047's streaming-asset-loading roadmap, which remains the
  actual gating cost for a real game on constrained hardware.
