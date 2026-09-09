# 108. Attempted: offload all of mruby-rpg2k's compiled bytecode to the SD card

Date: 2026-09-09

## Status

Accepted (as a real, honestly-reported negative result -- see Consequences)

## Context

After ADR 107 split `Game::Battle` out and excluded it (with `scene/battle.rb`/
`scene/battle_rpg2k3.rb`) from the wio build, `env:wio_rgss_boot` still
overflows flash by 1,111,092 bytes -- about 2.2x its budget -- with
`game.rb`'s remaining bulk and `scene/map.rb` named as the largest levers
left, neither of which has a safe exclusion boundary the way battle did (no
feature short of the whole engine can be cut without still being reachable
from an ordinary play session).

`mruby-rpg2k/src/rgss_ext.cxx` is two empty stub functions
(`mrb_mruby_rpg2k_gem_init`/`_gem_final`) -- this gem carries no native C/C++
of its own, only `mrblib/*.rb`. That makes "compile it to a standalone `.mrb`
and load it from the SD card at boot via `mrb_load_irep_buf`, instead of
baking it into firmware flash" a real candidate, the same mechanism ADR 99's
own smoke test already used for a small slice of `mruby-lcf`'s schema. This
ADR is the requested attempt: try offloading the *whole* gem first (scene-
level loading is the fallback if whole-gem doesn't fit).

## Decision

**Built the mechanism (`RGSS_WIO_EXTERNAL_RPG2K`).** `mruby-rpg2k/mrbgem.rake`
gained an env-var-gated branch, checked *before* the existing wio-only
battle trim so it supersedes it wherever set:

```ruby
if ENV['RGSS_WIO_EXTERNAL_RPG2K']
  spec.rbfiles = []
elsif build.name == 'wio'
  spec.rbfiles -= %W[...battle files...]
end
```

Deliberately not scoped to `build.name == 'wio'`: a *host* build with the
var set is exactly what this ADR's own proof needed -- a native, single-
format (rpg2k + rgss + lcf, matching wio's own `single_format_only` gem set)
`libmruby.a` with zero rpg2k Ruby compiled in, without needing the ARM
toolchain to prove the loading mechanism.

**Host-side proof: the mechanism works.** A small standalone program
(mirrors `app/wio/src/wio_rgss_boot_main.cxx`'s own
`mrb_open_core()` + `rpg_maker_init_shared_gems` + `rpg_maker_init_rpg2k_gem`
two-step) confirmed, in order:

1. With `RGSS_WIO_EXTERNAL_RPG2K=1`, `Game::Party` is *not* defined after the
   normal gem-init two-step (the exclusion really works, for a host build
   too, not just wio).
2. `mrb_load_irep_buf` on a real 676,583-byte RITE binary -- `mrbc`-compiled
   from all 17 real `mruby-rpg2k/mrblib/**/*.rb` files (the same
   `Dir.glob(...).sort` order `spec.rbfiles` uses by default, minus the
   three already-dead debug-tool files ADR 97 trims) -- completes with no
   exception.
3. `Game::Party`, `Game::Actor` and `Game::Battle` are all defined
   afterward, and `Game::Actor::ROW_FRONT` (ADR 107's own constant) reads
   back as a real Fixnum through the C API, not just "class exists."

One real bug found and fixed along the way, in the proof harness itself, not
in the gem: the first version's constant-path walker used
`mrb_class_get_under`, which hard-requires `MRB_TT_CLASS` and raised "wrong
argument type Module (expected Class)" the moment it reached the `Game`
namespace -- `Game` is `module Game`, not `class Game`. Switched to
`mrb_const_get`, which resolves either.

**Real relink: doesn't fit, even at zero rpg2k Ruby.** Rebuilt the actual
wio-target `libmruby.a` (`MRUBY_TARGET=wio rake`) with
`RGSS_WIO_EXTERNAL_RPG2K=1` and relinked `env:wio_rgss_boot` for real:

| state | FLASH overflow |
| --- | --- |
| ADR 107 (battle excluded) | 1,111,092 |
| + **all** of mruby-rpg2k's Ruby excluded | **510,340** |

600,752 bytes recovered -- real, and the single largest lever this whole
series has found. But the board's actual flash budget (PlatformIO's own
linker script reserves a 16 KB bootloader region: 507,904 usable bytes, not
the raw 512 KB) is still **exceeded by 510,340 bytes with zero rpg2k Ruby
compiled in at all** -- a firmware that boots the interpreter, RGSS and LVGL
and loads *no game logic whatsoever* is already more than 2x over budget.
RAM easily fits at this state (as it already did after ADR 107; removing
more bytecode only helps further).

**The Renode hardware/RAM test was not run.** ADR 99's own smoke test
already found that loading a ~54-60 KB *pure schema* payload via
`mrb_load_irep_buf` on real (emulated) Wio hardware nearly exhausted its
192 KB RAM outright, and documented that this cost scales with total
compiled bytecode size, not with how much is actually live. The rpg2k
payload here is 676,583 bytes -- over 10x that. Running the real hardware
test would very likely just reproduce a RAM-exhaustion crash the prior ADR
already predicts in detail, and -- more importantly -- **the flash number
above already rules the whole-gem approach out regardless of what RAM does**:
even a hypothetical zero-RAM-cost loader would still leave the board 510,340
bytes over its flash budget. Spending a real hardware/emulator run to
confirm a failure mode that cannot change the outcome was not worth it here;
if scene-level loading (below) ever gets far enough to be RAM-plausible, that
is where a real Renode SD-card boot test earns its cost.

## Consequences

- **The mechanism is proven, not the outcome.** `mrb_load_irep_buf` can load
  this entire gem's compiled Ruby back into a running interpreter and have
  it work correctly (real classes, real constants) -- that part of the
  original question is answered, cleanly, for good. But it does not get the
  Wio Terminal to fit, not even close, because of what it reveals next.
- **The real remaining blocker is no longer mruby-rpg2k's Ruby at all.** With
  100% of it removed, 1,018,244 bytes (507,904 budget + 510,340 overflow) of
  interpreter + RGSS + LVGL + uni-algo + Arduino framework code is what's
  left -- more than double the entire flash budget by itself. Any further
  work on this port's flash budget has to target *that*, not the game's own
  script content, which has essentially nothing left to give beyond what
  ADR 105/106/107 already took.
- **Scene-level loading (the user's own suggested fallback) does not change
  this floor.** Whichever granularity rpg2k's Ruby is streamed from SD at --
  the whole gem at once, or one scene at a time -- none of it sits in flash
  either way, so the flash savings are identical (600,752 bytes) regardless
  of loading strategy. Scene-level loading is a real, distinct idea worth
  its own investigation, but only as a fix for the *RAM* problem ADR 99
  found (loading less bytecode at once costs less transient interpreter
  overhead) -- it cannot, by itself or in any granularity, close a
  510,340-byte flash gap that exists with zero rpg2k content loaded at all.
- `RGSS_WIO_EXTERNAL_RPG2K` is left in `mruby-rpg2k/mrbgem.rake`: a no-op
  unless set, and the only way this ADR's own numbers are reproducible. It
  is not wired into any real build (wio's own `platformio.ini` environments
  do not set it), the same as `RGSS_WIO_STUB_HEADERS`/
  `RGSS_WIO_ARDUINO_INCLUDES` before it.
- No runtime SD-bytecode loader was written for firmware use (unlike ADR
  99's own smoke test, which did ship one) -- with the flash question
  answered negatively before RAM was even tested, there is nothing yet
  worth loading it *into*. That loader is real follow-up work only once a
  future attempt actually shrinks the ~1 MB skeleton enough for rpg2k's own
  content to matter again.
