# 99. Loading mrblib bytecode from a file instead of embedding it: mechanism and real numbers

Date: 2026-09-08

## Status

Accepted

Design record and mechanism verification, now including a real
Renode-emulated-hardware boot (see "On real (emulated) hardware" below).
Still no *shipped* runtime or build code — matching ADR 0007's own P0,
this is budget before code, because the thing this would wire into
(wio's own `libmruby.a` link) does not exist yet (see Consequences) — but
the mechanism itself is no longer just a host-side claim.

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

## On real (emulated) hardware

The round-trip above ran on the x86-64 host. `app/wio/src/mruby_sd_smoke_main.cxx`
(a scratch smoke test, not part of the shipped firmware) reruns the same
check on the Wio's own Cortex-M4, under Renode built from source with this
project's own SAMD51/ILI9341 peripherals (`scripts/wio_renode_build.bash`):
reads a plain RITE binary off an emulated SD card
(`scripts/wio_renode_sdcard.bash`), loads it with `mrb_load_irep_buf`,
and checks the resulting `LCF::Schema` constants through mruby's C API,
reporting pass/fail as a magic value in a fixed global Renode reads back
with `sysbus ReadDoubleWord` (no UART model needed). It passed — `0xC0FFEE42`
read back after a real boot, real SD read, real bytecode load, real Ruby
constant lookups.

Getting there surfaced two real bugs neither the host round-trip nor
ADR 0098's own measurements could have found, since both need an actual
32-bit target:

- **`mrb_int` size mismatch.** `build_config.rb`'s host `mrbc` (used to
  compile bytecode for every target, cross builds included) defaults to
  `MRB_INT64` — `mrbconf.h`'s own auto-detection picks it for any 64-bit
  host — while psp/wio cross targets default to `MRB_INT32`. `mruby-lcf`'s
  own `schema.rb` has a literal that lands in exactly the gap: too big for
  32 bits, small enough that mruby doesn't promote it to an arbitrary-
  precision bignum (a compile-time constant-folded computation reducing to
  `2251799813685248`) — so the host `mrbc` emits an `IREP_TT_INT64` pool
  entry, and the 32-bit reader's own `case IREP_TT_INT64: #else return
  FALSE #endif` (`3rd/mruby/src/load.c`) can't parse it at all. The
  failure surfaces as a bare `ScriptError` ("irep load error") with no
  hint that a specific literal, let alone its size, is the cause — found
  by patching a debug line-number marker into a local, uncommitted copy of
  `load.c`'s 24 `return FALSE` sites and re-running under Renode until one
  actually fired, not by inspection. **Not fixed in `build_config.rb`** —
  forcing `MRB_INT32` onto the shared host build would also change
  desktop/wasm/android, and that deserves its own real look rather than a
  rushed one here. Worked around for this smoke test only, with a scratch
  host `mrbc` forcing `MRB_INT32` to match the cross target.
- **A real memory ceiling, not just a theoretical one.** Loading
  `mruby-lcf`'s *entire* `schema.rb` (all 25 record types, ~930 fields,
  ADR 0098's own count) this way raises `NoMemoryError` on the Wio's
  192 KB SRAM under a stock Arduino SAMD malloc arena — confirmed by
  reading back the raised exception's own class name from memory, not
  assumed from the `NoMemoryError` result code alone. A smaller, still
  real slice (`COMMON_EVENT` through `BATTLER_ANIMATION`, ~27 fields —
  the same slice the schema-hash-literal A/B mentioned in ADR 0097 used)
  loads and executes cleanly. Streaming or splitting the schema so the
  full thing fits is real follow-up work this surfaced, not something
  either ADR attempts.

Neither finding is specific to *this* ADR's file-loading mechanism — both
would equally bite the existing cdump path the moment anyone actually
boots psp/wio's mruby build on real silicon (or, for the int-size bug, an
emulator) for the first time. They surfaced here because this is the
first time in the project's history anything has: psp's bring-up EBOOT
and the Wio firmware have both linked `libmruby.a` only during a `rake`
build, never during a real boot, until this smoke test's `pio run`
existed to make one.

## Schema laziness: a real, partial fix for the memory ceiling

Finding 2 above came from `schema.rb` building all ~930 fields' worth of
nested Hash/Symbol objects the moment the file loads — DATABASE's own
17 largest per-record-type `elements:` values, plus 15 more standalone
top-level constants referenced the same way (`SAVE_SYSTEM`, `SAVE_MOVABLE`,
`SAVE_PICTURE`, ...), are now `-> { {...} }` lambdas instead, resolved and
cached in place on first real access (`LCF.elements_of`, `mruby-lcf/mrblib/
lcf.rb`) — the same lazy-decode philosophy `Array1D#[]`/`Array2D#[]` already
apply to *data*, extended to the schema *descriptors* themselves. A few
constants that are only ever consumed through a fresh, throwaway `{
elements: SAVE_X }` wrapper built on every call (`mruby-rpg2k/mrblib/
game.rb`'s `Game::State#to_lsd`/`.from_lsd`) self-memoize instead
(`Schema.lazy`, `mruby-lcf/mrblib/schema.rb`), so the block still runs only
once per process rather than once per save. `DATABASE`/`MAP_UNIT`/
`MAP_TREE`/`SAVE_DATA`'s own outer Hashes stay eager — each is used as a
`.ldb`/`.lmu`/`.lmt`/`.lsd` file's *root* schema directly
(`LCF::Database#schema`, etc., accessing `schema[:type]` straight off it),
never reached through the `elements:` indirection `LCF.elements_of`
generically resolves, so wrapping the outer Hash itself would break that
access rather than defer it — confirmed the hard way: an earlier pass
wrapped `MAP_UNIT` outright and `ArgumentError: wrong number of arguments
(given 1, expected 0)` came back from `Proc#[]` (`schema[:type]` on an
unresolved Proc silently means `schema.call(:type)`, not a `NoMethodError`
that would have been obvious).

Correctness is verified two ways, not just asserted: an automated
deep-resolve comparison (force every lambda across all of `LCF::Schema`'s
constants, recursively, then diff the result against the same walk over
the pre-change file) comes back byte-for-byte identical, and the existing
`ctest -R mruby_test` suite (2052 assertions, `mruby-lcf/test/lcf_test.rb`
included) passes unchanged. One real bug the deep-resolve comparison
caught before it shipped: `SAVE_MOVABLE[108] = {...}`, a post-definition
mutation adding a field once `SAVE_EVENT_EXEC_STATE` existed (added later
in the file, so the assignment couldn't be inlined at `SAVE_MOVABLE`'s own
original definition site) — raised `NoMethodError: undefined method '[]='
for an instance of Proc` the moment `SAVE_MOVABLE` became lazy. Fixed by
moving field 108 into `SAVE_MOVABLE`'s own literal outright: laziness
means the forward reference to `SAVE_EVENT_EXEC_STATE` no longer needs to
wait for that constant to exist, only for someone to actually resolve
`SAVE_MOVABLE`'s elements, which happens well after the whole file has
loaded.

On real (emulated) hardware this closes *part* of finding 2, not all of
it. `mruby_sd_smoke_main.cxx` reran with the real, complete, unmodified-
content `schema.rb` + `lcf.rb` (~54 KB compiled, no reduced slice) and
this time `mrb_load_irep_buf` succeeded — something the pre-laziness file
could not do at all under the same harness. Getting even that far needed
shrinking the smoke test's own static SD-read buffer from 64 KB to 60 KB;
there was no headroom left over past the load itself. Resolving even one
record type's fields afterward (`DATABASE` chunk 11 "player", ~30 fields,
reached the same way `Array1D#sym2idx` would — through the lazy
`elements:` lambda) still exhausts what little remains and crashes the
same way the original all-eager file did (lands in newlib's `abort`/`_exit`
path, not a catchable `mrb->exc` — consistent with mruby's own "out of
memory while raising `NoMemoryError`" fallback). The likely dominant
remaining costs are not schema data at all: the interpreter's own IREP
structures for ~54 KB of bytecode scale with total compiled size
regardless of how much Ruby data ends up live, and `lcf.rb`'s ~700 lines
of real reader/writer code do not shrink just because `schema.rb`'s data
got lazier. Closing the rest for real looks like `mrb_load_irep_file`
streamed from an actual `FILE*` (`app/wio/src/sd_syscalls.cxx` already
provides the newlib `_open`/`_read` plumbing for this, gated by
`WIO_WITH_SD`, and is unused today) instead of this smoke test's whole-
file-into-a-static-buffer `mrb_load_irep_buf`, which needs the entire
compiled size resident in RAM on top of whatever the parse itself
allocates — real follow-up work this update surfaced, not something it
attempts.

## Consequences

- **There is nowhere to wire this in yet.** `app/psp`'s bring-up EBOOT does
  not link `libmruby.a`; the Wio firmware does not link it at all (ADR
  0007's own P1/P2 boundary). This ADR's mechanism is validated in
  isolation, ready for whichever slice actually starts the interpreter on
  either board, rather than half-wired into a boot path that does not
  exist.
- **SD read *works* under Renode now (see above); latency is still not
  measured.** Renode models `SD.SDCard`'s real wire protocol, not its
  timing characteristics in detail, and this smoke test's own file is a
  single ~1 KB read at boot, not the 730-870 KB whole-stack figure this
  ADR's own numbers are about. "Load hundreds of KB from an SD card once
  at boot" is now a design claim backed by *a* working read, not yet a
  timing budget for *the* real one.
- **The file-loading path needs a filesystem** — `app/wio/src/sd_syscalls.cxx`
  (routing newlib `_open`/`_read` to the microSD card, gated by
  `WIO_WITH_SD`) already exists for exactly this and is unused today; QSPI
  XIP (map the flash chip directly into address space, no read call at
  all) is a different, bigger lever this ADR does not attempt.
- **Two real, actionable bugs came out of the first-ever real boot.** The
  host/cross `mrb_int` size mismatch (`MRB_INT64` vs `MRB_INT32`, see
  above) is not this ADR's to fix — it affects *any* build touching
  psp/wio, cdump included, the moment a `.rb` file anywhere in the gem
  stack has a literal in the 33-to-64-bit range, not just files loaded
  this ADR's way. The schema memory ceiling *is* this ADR's own smoke test
  finding to carry forward: "Schema laziness" above lands a real, verified
  fix for the part of it that was `schema.rb` eagerly building data it
  might never use, but real-hardware testing found that alone does not
  clear the Wio's 192 KB SRAM for the *whole* file — the remaining gap
  looks like it's in the interpreter's own bytecode-loading overhead and
  `lcf.rb`'s code size, not schema data, and needs the streaming-load
  lever (`mrb_load_irep_file` over a real `FILE*`) that section's own last
  paragraph names as the likely next step.
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
