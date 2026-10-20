# LCF::Schema save-state tables: eager vs lazy footprint

> **Historical record.** The `wio` build named here was removed; `closed` is its successor. Figures are as measured then.

Measurement behind PR #2360, which turned the 15 save-state tables in
`mruby-lcf/mrblib/schema.rb` from `lazy { { ... } }` wrappers (built on first
`.call`) into plain Hash constants built at module load. This note records what
the eager build costs in heap and load time, on a host stand-in for the PSP and
Wio builds. It is a host measurement, not a device one; see the caveats.

## Verdict

- **PSP: not a concern.** The eager tables add about 12 KB of heap on a 32-bit
  `mrb_int` VM, roughly 0.3% of the 4 MB mruby pool (ADR 0047).
- **Wio: a real cost, not yet confirmed on hardware.** The same ~12 KB is about
  6% of the Wio's 192 KB SRAM (ADR 0007), a ceiling that ADR 0135 found binding.
  It is paid at boot whether or not a game ever saves or loads. Confirm with the
  Wio heap-dump environment before accepting it on that target.
- **Once a save or load has run, eager is not more expensive than lazy.** Forcing
  every lazy table costs more heap than the eager build does, and more load time.

Threshold used: 1% of the pool on PSP (about 40 KB), because the pool is far from
binding there. On Wio, 5% of total SRAM (about 9.6 KB), because ADR 0135 measured
the class and method tables alone at 160+ KB of that 192 KB.

## What was and was not measured

- No PSP SDK, no PlatformIO/Wio toolchain and no Emscripten SDK are available in
  the build environment, so no device number exists.
- Measured instead: native mruby 4.0 VMs built from the repo's `3rd/mruby`
  submodule, with the gems `mruby-lcf` needs at runtime (array, hash, enum,
  string, numeric ext and bigint), in two configurations:
  - `lcf32`: a true ILP32 build (`-m32`, 32-bit pointers), `MRB_INT32`, and the
    Wio constrained defines from `build_config.rb` (`MRB_HEAP_PAGE_SIZE=256`,
    `KHASH_INITIAL_SIZE=16`, `MRB_NO_IREP_DEBUG`, `MRB_STR_LENGTH_MAX=0`).
    This is the primary number.
  - `host`: the default 64-bit build, for comparison.
- Not measured: the PSP and Wio binaries themselves, Emscripten/wasm32 heap
  growth, and any on-device stack or flash effect.

## Method

- Baseline: `e9adf24c`, the first parent of merge `ba670206` (PR #2360). Its
  own commit is `14727fb9`, parent `2f78735b`. Current: `origin/master`
  (`fe9086fe`). Only `mruby-lcf/mrblib/schema.rb` differs between them.
- Three bundles: the baseline mrblib concatenated in the mrbgem file order
  (lazy, never resolved); the same bundle plus a line that calls all 15 lazy
  tables (lazy, fully resolved); and the current mrblib (eager). Each was
  compiled with the 64-bit host `mrbc -s`, as the cross builds do, and loaded
  into the 32-bit VM. The 32-bit VM loaded all three with no irep error.
- Each run opens a fresh `mrb_open()`, calls `mrb_full_gc`, loads the bundle with
  `mrb_load_irep_buf`, and calls `mrb_full_gc` again.
- Heap bytes: a counting `mrb_basic_alloc_func` (mruby's documented replacement
  hook) records payload bytes of live blocks. Allocator headers are excluded.
- Objects: `mrb->gc.live` and `mrb->gc.tt_live[...]` after the full GC.
- Load time: the median over 1000 runs, each in a fresh VM, two repetitions.
  Compile time is excluded.

## Results (lcf32, 32-bit `mrb_int`, 32-bit pointers)

Heap delta is the bytes after loading minus the bytes after `mrb_open()`
(36,308 on lcf32).

| Variant | Heap delta (bytes) | Live object delta | Hash / String / Array / Proc delta | Load median (us) |
| --- | ---: | ---: | --- | ---: |
| lazy, never resolved (baseline) | 164,810 | 1,069 | 127 / 34 / 3 / 800 | 2,758 - 2,774 |
| lazy, all 15 resolved | 179,223 | 1,373 | 405 / 37 / 7 / 801 | 2,823 - 2,855 |
| eager (`origin/master`) | 176,742 | 1,322 | 405 / 37 / 6 / 769 | 2,441 - 2,470 |

- Eager against lazy-never-resolved: +11,932 bytes (+7.2%), +253 live objects,
  +278 Hashes. Load is about 300 us faster.
- Eager against lazy-resolved: -2,481 bytes, -51 live objects. Load is about
  400 us faster.

## Results (host, 64-bit `mrb_int`, 64-bit pointers), for comparison

| Variant | Heap delta (bytes) | Live object delta | Load median (us, 200 runs) |
| --- | ---: | ---: | ---: |
| lazy, never resolved | 236,661 | 1,067 | 2,647 |
| lazy, all 15 resolved | 254,594 | 1,354 | 2,758 |
| eager | 250,437 | 1,303 | 2,241 |

On 64-bit the eager increment is +13,776 bytes against lazy-never-resolved and
-4,157 bytes against lazy-resolved, the same pattern as above.

## Why the load time is lower (not verified)

The lazy form compiles each `lazy { ... }` body as its own block. The likely
cause of the lower eager load time is that the eager form has fewer of those
blocks to read on each load. This was not checked by counting ireps.

## 32-bit `mrb_int` and bignums

- `schema.rb` has no integer literal wider than 32 bits. A grep for long decimal
  or hex literals, and for `<<` or `**`, matched only comments.
- The eager change adds no arithmetic. Each table value is the same literal as
  before. The #2360 commit message records a CRuby dump check that the values
  match; that check was not re-run here.
- The `lcf32` VM loaded all three bundles with no `irep load error`, which is the
  failure AGENTS.md describes for a bignum constant folded by a 64-bit `mrbc`.

## Caveats

- Host, not device. The `lcf32` build is x86 with `-m32`. ARM and MIPS struct
  sizes and allocators differ.
- The allocator header is not counted. A newlib-style allocator adds its own
  per-block overhead. As a rough estimate, about 280 extra Hashes could add
  2 to 4 KB on a device, so the Wio number is probably somewhat higher than 12 KB.
  This is an estimate, not a measurement.
- The Wio build also rewrites some mrblib at build time (`scripts/wio/strip_*`).
  That pass is not reproduced here, so the schema bundle was not checked against
  it.
- Emscripten is unmeasured. wasm32 has 32-bit pointers, so the `lcf32` numbers
  are the closer proxy. wasm heap grows on demand, so there is no fixed ceiling
  as on the handhelds.

## Reproduction

The harness and build config are not committed. They are a minimal
`MRuby::Build` config (`host` and `lcf32` builds, the same gem list), a 60-line
C harness that redefines `mrb_basic_alloc_func`, and the concatenated mrblib
bundles compiled with `build/host/bin/mrbc -s`. Build with the `gperf` package
and a `host` target present, since `mruby-compiler` looks it up by that name.
