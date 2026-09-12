# 142. A real `wio_rgss_boot` flash/RAM measurement of `RPGMAKER_BC2CPP=1`, at its current coverage scope

Date: 2026-09-12

## Status

Accepted

## Context

`RPGMAKER_BC2CPP=1` (`build_config.rb`, gating `mruby-lcf-compiled`/
`mruby-rgss-compiled`/`mruby-rpg2k-compiled`) has grown through roughly 30
rounds of coverage work (docs/adr/0139), now covering LCF::File's own
bytecode methods, all 17 of RGSS::Sprite's real methods, 25 of Game::
Picture's 26 methods, all 6 of Game::EnemyAction's methods, and a growing
set of `RPG2k::Scene::Map`/`Battle`, `Game::Interpreter`, and `.singleton`
owner clusters. Every round's own before/after numbers so far have been
isolated `.o`/whole-gem-bytecode proxy measurements (the same category
docs/adr/0130 flagged as "never expected to match exactly" a real link) —
nobody had run a real `pio run -e wio_rgss_boot` link with and without the
flag, at the *current* coverage scope, to see what it actually costs or
saves on the real embedded target. This ADR does exactly that, following
the same cross-compile process docs/adr/0130/0133/0135 already established
and re-verified working in this sandbox (same 9 mruby-family patches, same
Unicode table downloads, same `RGSS_WIO_ARDUINO_INCLUDES` extraction, same
GCC 14.2.1 toolchain, no `-flto`).

Two real, clean `MRUBY_TARGET=wio rake` cross-compiles (`rm -rf 3rd/mruby/
build/wio` between them; `3rd/mruby/build/host` reused unchanged — it only
supplies the `mrbc` bootstrap compiler, whose own gem set does not depend
on `RPGMAKER_BC2CPP`), a matching standalone `arm-none-eabi` `libuni-algo.a`
build (shared, unaffected by the flag), and two real `pio run -e
wio_rgss_boot` links from a clean `.pio/build/wio_rgss_boot`.

## What was measured

Both links fail on the real `FLASH` region overflow (this target has not
fit since docs/adr/0104 first linked it — see docs/adr/0140/0141 for the
current, non-bc2cpp overflow's own category breakdown) — `ld` still
completes real, full section layout before refusing to emit `firmware.elf`,
so `firmware.map` carries exact, real `.text`/`.data`/`.bss` sizes both
times, not an estimate:

| | baseline (no bc2cpp) | `RPGMAKER_BC2CPP=1` | delta |
| --- | ---: | ---: | ---: |
| `.text` (flash) | 1,167,296 | 2,190,496 | **+1,023,200** |
| `.data` (RAM) | 12,880 | 12,880 | 0 |
| `.bss` (RAM) | 19,360 | 19,360 | 0 |
| **Flash needed** (507,904 budget + real `ld` overflow) | **1,183,864** (233.1%) | **2,229,304** (438.9%) | **+1,045,440** |
| **RAM used** (`.data`+`.bss` of 196,608 budget) | **32,240** (16.4%) | **32,240** (16.4%) | **0** |
| real `ld` "region FLASH overflowed by" | 675,960 | 1,721,400 | +1,045,440 |

Confirmed the baseline number against docs/adr/0140's own independently
recorded post-JPEG-trim figure (675,960 bytes) — an exact match, not just a
plausible ballpark, giving real confidence this session's cross-compile
process reproduces the project's current, real state rather than some
stale or drifted one.

**RAM (`.data`+`.bss`) is bit-for-bit identical with the flag on or off.**
This is expected, not a measurement error: `.data`/`.bss` are compile-time
static storage — global/static variables and their initializers — and
bc2cpp does not add or remove any of those; every AOT-compiled method is
still registered into its class's method table via a normal
`mrb_define_method` call at gem-init time, exactly like every interpreted
method, whether that call installs an `MRB_METHOD_FUNC` (bc2cpp) or a
bytecode-`RProc` (interpreted). **This measurement cannot see the runtime
heap cost docs/adr/0136/0137 already found and measured separately** (the
262 KB of heap growth building 2,485 live `RProc`s and 220 method tables
during gem-init) — that lives in `_sbrk`'s heap, not `.data`/`.bss`, and
would need the same live GDB/Renode heap walk those ADRs used, against a
bc2cpp build, to answer whether AOT compilation changes it. That walk is
real, separate, and substantially larger work (a widened-RAM diagnostic
build, `wio_rgss_boot_heapdbg_ram`, booted under Renode) — deliberately out
of scope here, per this ADR's own task: a real *static* link-time
measurement, not a repeat of that live-heap investigation.

### Where the +1,045,440 flash bytes actually go

Per-object-file sizes (`arm-none-eabi-size`) of the three compiled gems'
generated `register.o`, from the `RPGMAKER_BC2CPP=1` build:

| gem | methods covered | `register.cxx` source | `register.o` `.text` |
| --- | ---: | ---: | ---: |
| `mruby-lcf-compiled` | 7 (LCF::File family) | 364 lines / 23 KB | 11,031 bytes |
| `mruby-rgss-compiled` | 17 (RGSS::Sprite) | 485 lines / 30 KB | 25,878 bytes |
| `mruby-rpg2k-compiled` | 31 (Game::Picture ×25, Game::EnemyAction ×6) | 6,019 lines / 379 KB | **1,047,376 bytes** |

**`mruby-rpg2k-compiled`'s own `register.o` alone (1,047,376 bytes) accounts
for essentially the entire +1,045,440-byte real flash delta this ADR
measured** — `mruby-lcf-compiled` and `mruby-rgss-compiled` together cost
only 36,909 bytes, a small, unremarkable amount for what they cover. This
is not "AOT compilation is expensive in general": it is one specific gem's
current generated code being wildly disproportionate to what it covers —
31 methods costing over 100x what 17 comparable RGSS::Sprite methods cost,
and roughly 12x more *source lines per method* than the RGSS gem
(6,019/31 ≈ 194 lines/method vs. 485/17 ≈ 29 lines/method) — a real,
specific inefficiency in this round's own codegen for Game::Picture/
Game::EnemyAction (not investigated further here — this ADR does not touch
`tools/bc2cpp/`, per its own scope), not evidence against the AOT approach
itself.

## Decision

No code change — this is a measurement-only ADR, same shape as docs/adr/
0137. The real numbers stand as measured above.

## Consequences

- **At its current coverage scope, `RPGMAKER_BC2CPP=1` is a clear net loss
  on `wio_rgss_boot`'s real flash budget**: +1,045,440 bytes (roughly 1 MB),
  against a board that was already 675,960 bytes over budget without it.
  Turning it on for wio would need the firmware to fit in 507,904 bytes
  *twice as tightly* as it already does not.
- **It is a wash, not a win, on real static RAM** (`.data`+`.bss`
  unchanged) — neither confirming nor refuting docs/adr/0135/0136's own
  hypothesis that reducing live method/`RProc` construction could shrink
  the much larger 296,152-byte runtime *heap* shortfall those ADRs found.
  Answering that needs a live heap walk against a bc2cpp build (the same
  technique docs/adr/0136/0137 already built and this ADR deliberately did
  not repeat), not a static link-time number.
- **The flash cost is not evenly distributed across bc2cpp's own coverage.**
  `mruby-lcf-compiled` (LCF::File) and `mruby-rgss-compiled` (RGSS::Sprite)
  cost a combined 36,909 bytes for 24 methods — modest, plausible AOT
  overhead. `mruby-rpg2k-compiled` (Game::Picture/EnemyAction) alone costs
  1,047,376 bytes for 31 methods — a genuine outlier, not representative of
  what "the other ~2/3 of bc2cpp's ~60-class coverage" would cost if
  measured the same way. A future round revisiting `tools/bc2cpp/`'s own
  Game::Picture/EnemyAction codegen path specifically (why it emits ~194
  source lines and ~34 KB of object code per method against RGSS::Sprite's
  ~29 lines and ~1.5 KB) could plausibly recover most of this ADR's own
  measured regression without touching the AOT approach itself — flagged
  here, not pursued (out of this ADR's own scope, and `tools/bc2cpp/` is
  explicitly off-limits to the session that produced this measurement).
- **Neither build boots or fits regardless of this flag** — both `pio run
  -e wio_rgss_boot` links fail on the same real `FLASH` region overflow
  docs/adr/0104 through 0141 already established as this target's dominant,
  unresolved blocker; this ADR's own comparison is a real, controlled A/B
  on top of that shared, still-unfit baseline, not a claim that either
  configuration produces working firmware.
- **Do not generalize this one data point to "full-engine bc2cpp AOT."**
  bc2cpp's own coverage (per docs/adr/0139's round-by-round log) reaches
  only a hand-picked, partial subset of methods in most classes it touches,
  and touches only a handful of the map/battle/interpreter engine's full
  class set at all — this measurement reflects exactly the current,
  partial scope, not a hypothetical fully-AOT-compiled engine.
