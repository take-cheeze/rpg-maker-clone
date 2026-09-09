# 112. Point LVGL's malloc/string/sprintf at newlib instead of its own built-in implementations

Date: 2026-09-09

## Status

Accepted

## Context

`app/wio/lv_conf.h` left `LV_USE_STDLIB_MALLOC`/`STRING`/`SPRINTF` at their
default, `LV_STDLIB_BUILTIN`: LVGL's own TLSF allocator (`lv_tlsf.c` +
`lv_mem_core_builtin.c`), its own `lv_string_builtin.c`, and its own
`lv_sprintf_builtin.c`, backed by a static `LV_MEM_SIZE` pool (`40 * 1024U`
bytes) reserved in `.bss` up front.

Looking for further flash/RAM to reclaim, `lv_mem_core_builtin.c.o` stood
out in `firmware.map` as LVGL's single largest live object file --
41,627 bytes. That number is misleading: `nm`/`size` on it shows only
~610 bytes of actual `.text` (`lv_malloc_core`, `lv_realloc_core`,
`lv_free_core`, `lv_mem_init`, etc.); the other 40,960 bytes are
`.bss.work_mem_int` -- the static pool itself, sized by `LV_MEM_SIZE`.
It is RAM, not flash, and does not appear in any flash-focused number this
series has reported.

mruby's own GC already links newlib's `malloc`/`realloc`/`free`
unconditionally, on every build, regardless of this setting -- LVGL's
built-in allocator was never saving a dependency, only adding a second,
statically-sized heap next to the one already there. Same story for
`lv_string_builtin.c` (LVGL's own `memcpy`/`strlen`/etc.) and
`lv_sprintf_builtin.c` (LVGL's own `%d`/`%s`-only formatter): both
libc equivalents are already in the link for other reasons.

## Decision

Switch all three to `LV_STDLIB_CLIB`, LVGL's official pass-through backend
(`3rd/lvgl/src/stdlib/clib/*.c`): `lv_malloc_core`/`lv_realloc_core`/
`lv_free_core` call `malloc`/`realloc`/`free` directly, `lv_string_clib.c`
maps straight to the libc string functions, `lv_sprintf_clib.c` to
`vsnprintf`. `lv_mem_add_pool`/`lv_mem_remove_pool`/`lv_mem_monitor_core`/
`lv_mem_test_core` become no-ops in this backend -- none are used by this
firmware (no custom LVGL memory pools, no memory-monitor UI, no built-in
self-test), so nothing is lost. `LV_MEM_SIZE` no longer means anything and
is removed from `lv_conf.h`.

Net effect: LVGL's malloc/string/sprintf draw from the same dynamic newlib
heap mruby's GC already uses, instead of reserving a second, fixed-size
40 KB pool whether the (canvas/image/label-only) bring-up firmware needs it
or not.

### What was measured

A real relink, `env:wio_rgss_boot`, on top of ADR 111's state (build-time
CP932 tables, no opt-in SD offloads):

| | `.data` | `.bss` | RAM used | RAM headroom (of 196,608) | FLASH overflow |
| --- | --- | --- | --- | --- | --- |
| `LV_STDLIB_BUILTIN` (prior default) | 125,872 | 64,296 | 190,168 | 6,440 (3.3%) | 1,297,444 |
| `LV_STDLIB_CLIB` | 125,872 | 23,312 | 149,184 | 47,424 (24.1%) | 1,295,004 |

**+40,984 bytes of RAM headroom** (`.bss` drop of 40,984, matching the
removed 40,960-byte pool almost exactly) and **2,440 bytes of flash**,
confirmed by diffing every object's per-section sizes between both real
firmware.map outputs (only 9 objects differ at all: the four `_builtin.c.o`
files disappear, the three `_clib.c.o` files appear in their place at a few
hundred bytes each, and `strncat`/`strnlen` newly pull in ~100 bytes total
of newlib code CLIB's string backend needed that BUILTIN's didn't) -- there
is no unexplained growth elsewhere; the flash win is genuinely just the
allocator/formatter code itself, most of what looked like a 41 KB object
was RAM the whole time.

Given this board shipped ADR 107's port with the RAM budget already fit to
zero margin, and this session's own ADR 111 fix trimmed that margin further
(to 6,440 bytes, 3.3%) to remove a real heap-corruption risk, this is the
single largest RAM win available without touching a feature -- headroom
that ADR 111's CP932 fix, and any future feature, was and is competing for.

### What was verified

- **Every changed object accounted for**: a full per-object-file diff
  between two real relinks (`LV_STDLIB_BUILTIN` vs `LV_STDLIB_CLIB`,
  otherwise identical tree) touches exactly 9 files -- the three builtin/
  clib pairs (mem core, string, sprintf) plus `lv_tlsf.c.o` (dropped
  entirely, no CLIB equivalent needed) and two newlib string objects
  (`strncat`, `strnlen`) newly pulled in by the CLIB string backend. No
  other object in the entire firmware changed size, ruling out any
  indirect effect on unrelated code.
- **The CLIB backend is LVGL's own real, released implementation** (not a
  stub written for this project) -- `3rd/lvgl/src/stdlib/clib/lv_mem_core_clib.c`
  is a straight `malloc`/`realloc`/`free` pass-through; the only stubbed
  functions (`lv_mem_add_pool`, `lv_mem_monitor_core`, `lv_mem_test_core`)
  are optional features this `lv_conf.h` doesn't exercise (no custom pools,
  no memory-monitor widget, no built-in self-test call anywhere in
  `app/wio` or `mruby-rgss`).

Not verified: real-hardware/Renode runtime behavior (LVGL rendering canvas
text through a live `malloc`-backed heap). This is a backend swap between
two heap implementations mruby's own allocator already exercises
constantly elsewhere in the same binary, not new or untested code, so the
risk is judged low -- but it has not been exercised under actual widget
churn on this board.

## Consequences

- LVGL and mruby now share one dynamic heap instead of splitting RAM
  between mruby's heap and a statically-reserved LVGL pool -- whichever
  side needs more at a given moment can have it, rather than 40 KB sitting
  reserved for LVGL even when the bring-up firmware's canvas/label usage
  needs far less.
- `lv_conf.h`'s `LV_MEM_SIZE` knob is gone; there is no longer a "make this
  bigger if LVGL runs out of memory" dial to turn -- allocation failures
  now show up as a `malloc` returning `NULL` (caught by
  `LV_USE_ASSERT_MALLOC`, already on) sharing the same failure mode as
  every other allocation in the firmware, rather than a separate LVGL-only
  ceiling.
- If a future feature needs LVGL's own memory pools, monitor, or built-in
  self-test, `LV_STDLIB_CLIB` does not provide them -- reverting to
  `LV_STDLIB_BUILTIN` for just that one sub-setting stays available if that
  ever matters (LVGL allows mixing backends per option).
