# 113. Make the GOTHIC SD font offload wio's default, not an opt-in

Date: 2026-09-09

## Status

Accepted

## Context

ADR 110 added `SHINONOME_GOTHIC_SD_FILE` / `RGSS_SHINONOME_GOTHIC_SD_PATH`
as a pair of no-op-unless-set escape hatches, the same convention as every
other measurement/opt-in knob this series has added -- real, verified,
164,816 bytes of flash recovered, but nothing in the tree actually set
either for a plain build.

That made sense while it was one option among several still being
evaluated. It no longer does: ADR 111's own CP932 RAM fix and ADR 112's
LVGL allocator swap both landed since, and this board's margin is still
the tightest resource in the whole port (ADR 107). A win this size, with
no real downside for *this* target specifically (see below), sitting
behind a flag nothing sets is just flash and RAM left on the table by
default.

## Decision

`build_config.rb`'s `wio` cross-build config now sets both env vars itself,
`||=` so an explicit override still wins:

```ruby
ENV['SHINONOME_GOTHIC_SD_FILE'] ||= 'gothic.bin'
ENV['RGSS_SHINONOME_GOTHIC_SD_PATH'] ||= '/gothic.bin'
```

placed where `wio` itself is computed, before either the host (`mrbc`-only)
or cross `MRuby::Build`/`MRuby::CrossBuild` configs run -- both call
`rpg_maker_gems`, which is what pulls in mruby-rgss's own `mrbgem.rake` and
reads these. Every other target (desktop, wasm, psp, android) is
unaffected: the `if wio` guard means the env vars are never touched unless
`MRUBY_TARGET=wio` is already set, and `gen_shinonome_data.rb`/
`mrbgem.rake` still treat them as plain opt-in flags -- this only changes
wio's own default, not the mechanism.

This does **not** wire up a real SD-card deployment step (ADR 110's own
"what was not done" already named that gap, and it still exists): the
build now always produces a `gothic.bin` next to mruby-rgss's own build
artifacts, but nothing copies it onto an actual card yet. On real hardware
with no such deployment, `find_gothic_char`'s SD fallback simply finds
nothing (a graceful miss, same as today), same as before this ADR --
because `app/wio/src/sd_syscalls.cxx` (the SD-backed newlib syscalls
`fopen` needs to reach the card at all) is itself a scaffold gated on
`WIO_WITH_SD`, which the `env:wio_rgss_boot` bring-up environment leaves
off. Confirmed the bring-up firmware's own `wio_rgss_boot_main.cxx` never
renders any text through `GOTHIC` either, compiled-in or SD-backed, so
there is no existing behavior this regresses -- kanji rendering was already
unexercised by this build, for a separate, pre-existing reason.

### What was measured

A real relink, `env:wio_rgss_boot`, on top of ADR 112's state:

| state | FLASH overflow | RAM used | RAM headroom (of 196,608) |
| --- | --- | --- | --- |
| ADR 112 (LVGL CLIB backend, GOTHIC still compiled in) | 1,295,004 | 149,184 | 47,424 |
| + GOTHIC SD offload on by default | 1,130,212 | 150,224 | 46,384 |

**164,792 bytes of flash recovered** (matching ADR 110's own original
164,816-byte measurement almost exactly), at a cost of 1,040 bytes of RAM
(the 64-slot lookup cache) -- still comfortably inside budget, 46,384 bytes
of headroom left. Verified the generated `gothic.bin`
(`3rd/mruby/build/wio/mrbgems/mruby-rgss/gothic.bin`, 165,100 bytes) and
the `RGSS_SHINONOME_GOTHIC_SD_PATH "/gothic.bin"` `#define` both land in
the real build without setting either env var by hand -- a plain
`MRUBY_TARGET=wio rake` now produces them on its own.

## Consequences

- A plain wio build (no env vars set) now ships the GOTHIC face off flash
  by default -- the single largest remaining opt-in win from this whole
  series is no longer opt-in.
- Getting a real device to actually *draw* kanji still needs two things
  neither this ADR nor ADR 110 provide: `WIO_WITH_SD` wired into a real
  boot environment (today only the bring-up `env:wio_rgss_boot`, which
  never loads game data or exercises `WIO_WITH_SD`, exists), and an actual
  deployment step that copies the build's own `gothic.bin` onto the card at
  the path `RGSS_SHINONOME_GOTHIC_SD_PATH` names. Both remain future work.
- A measurement build that wants the old compiled-in GOTHIC array back
  (e.g. to re-run ADR 104's original flash breakdown) can still get it by
  setting `SHINONOME_GOTHIC_SD_FILE`/`RGSS_SHINONOME_GOTHIC_SD_PATH`
  explicitly to something else before invoking `MRUBY_TARGET=wio rake` --
  the `||=` default only fills in what is otherwise unset.
