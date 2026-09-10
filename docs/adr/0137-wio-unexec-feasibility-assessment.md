# 137. Would an unexec-style pre-baked mruby image fit wio's RAM? A real census says no, not by itself

Date: 2026-09-10

## Status

Accepted (a feasibility assessment; no code shipped from this ADR)

## Context

Asked whether an "unexec"-style approach -- dump the fully-initialized
mruby heap as a binary image after `setup()`'s gem-init finishes, then load
that image directly at boot instead of re-running `mrb_open_core()` + both
gem-init calls -- could meaningfully cut wio's flash and RAM usage.

On this target, unexec is more tractable than on a general-purpose OS
(no ASLR, addresses fixed at link time, so a raw memory dump can be
position-dependent and just `memcpy`'d into place). But before committing
to building it -- a large, invasive undertaking: a real serializer against
mruby's own GC internals (heap pages, mark/color bits, symbol table) and a
matching on-device loader that hands the interpreter a valid `mrb_state`
without ever calling `mrb_load_irep` -- the load-bearing question is
whether it would even close docs/adr/0136's 99,544-byte RAM shortfall.
Reused that ADR's `wio_rgss_boot_heapdbg_ram` setup (setup() now runs to
real completion) to find out empirically.

## What was measured

At the same success breakpoint as ADR 136 (`g_result = kResultPass;`,
right after `mrb_full_gc(M)`), walked the live object graph for real via
GDB (`M->gc.heaps`' page list, `M->gc.live` = 4,586 confirmed exactly
against an independent walk that also counted 790 free slots across
21 pages of 256 objects each -- 4,586 + 790 = 5,376 = 21×256, so the walk
is complete and self-consistent):

| Category | Count | Notes |
|---|---|---|
| RProc (methods) | 2,485 | 54% of all live objects |
| REnv (closures) | 454 | `MRB_ENV_LEN`-summed stack: 3,416 bytes total (tiny per-env) |
| RArray | 692 | 627 embedded (zero extra cost), 65 heap: 6,872 bytes |
| RString | 406 | 313 embedded (zero extra cost), 93 heap: 19,976 bytes |
| RHash | 159 | ~8,076 bytes (rough estimate, entry-count based) |
| RClass/RModule/SClass | 337 | 220 have a non-empty method table; `iv` (constants) on all 337: ~11,656 bytes (rough estimate) |
| RIClass | 16 | |
| RObject | 7 | |
| RException/RData/other | ~14 | |

**Method tables (`mt`) alone: 51,360 bytes** across 220 classes/modules/
singleton-classes -- confirming docs/adr/0136's own suspicion that class/
method scaffolding, not string or array data, is the dominant cost.

**The IREP/bytecode itself costs nothing at RAM at all**: `mrb_load_proc`'s
own `proc` argument in every backtrace resolved to a flash address
(`<gem_mrblib_mruby_rpg2k_proc>` at `0xac6d8`, well inside the 0x0-0x200000
flash region, nowhere near RAM's `0x20000000` base) -- the `mrbc`/cdump
code-generation this project already uses places the compiled iseq/pool/
syms tables as `const` C data, read directly from flash. Every one of the
2,485 live Procs is a 20-byte RVALUE wrapper *pointing at* already-flash-
resident bytecode, not a copy of it. An unexec image gains nothing here;
the bytecode was already free.

## The number that answers the question

```
RVALUE headers (4,586 × 20 bytes)    91,720
method tables (mt)                   51,360
REnv stacks                           3,416
String heap buffers                  19,976
Array heap buffers                    6,872
Hash tables (rough)                   8,076
Class iv/constant tables (rough)     11,656
                                    --------
accounted so far                    193,076 bytes
```

Real usable heap on the board: 196,608 (total RAM) − 33,248 (`.data`/
`.bss`) = **163,360 bytes**.

**193,076 > 163,360 already, before counting the symbol table, the VM's
own top-level operand-stack array, or the 7 RObject instances' own `iv`
tables** -- none of which were included above (the walk covered class-level
`iv`, not `RObject`'s). The full current arena is 261,400 bytes; the
101,356 bytes accounted for above out of 153,544 total external-buffer
bytes leaves 52,188 bytes unexplained, some real (the missing categories
above) and some likely genuine incremental-growth waste (`mt_grow`'s own
doubling strategy abandons smaller tables to newlib's free list, which a
precomputed image would not need) -- but even attributing *all* of that
remainder to pure waste, the accounted-for floor alone already exceeds the
real board's usable heap by 29,716 bytes.

## Decision

**Do not build the unexec image dump/loader.** The measurement it was
gated on came back negative: even a theoretically perfect, zero-waste
pre-baked image still would not fit in 163,360 bytes, because the *object
count* itself -- not how efficiently those objects are packed -- is the
problem. 2,485 Procs and 220 method tables are a direct, roughly linear
function of how many RGSS/mruby-lcf/mruby-rpg2k methods get defined during
gem-init; unexec changes *how* that state gets built, not *how much* of it
exists afterward.

The real lever, confirmed by this data rather than assumed: **reduce how
much of RGSS/mruby-lcf/mruby-rpg2k gets defined at boot at all** --
loading only what a given save/scene actually needs (closer to the
SD-external-content direction docs/adr/0108 never finished) rather than
eagerly constructing every class and method up front, mirrors this
project's own flash-side conclusion (docs/adr/0135/0136) that the fix
needed is architectural, not a packing optimization.

## Consequences

- This closes the question docs/adr/0136 left open ("how much would
  unexec help") with a real, if partially estimated, number rather than
  leaving it as an unbounded "maybe" that could have justified a large
  engineering investment.
- The two rough estimates in this census (Hash: entry-count-based, not a
  real walk of mruby's early-array-vs-table hash representation; class
  `iv`: assumes a plain `iv_tbl*` rather than accounting for mruby's
  object-shape optimization, which may not even apply to class-level
  storage) do not change the conclusion -- the accounted-for floor already
  exceeds budget using only the categories measured with full confidence
  (RVALUE headers, method tables, REnv, String, Array: 173,344 bytes alone,
  already within 10,016 bytes of the ceiling before the two rough
  categories are added at all).
- No new diagnostic infrastructure was added by this ADR -- it reused
  `wio_rgss_boot_heapdbg_ram` from docs/adr/0136 as-is.
