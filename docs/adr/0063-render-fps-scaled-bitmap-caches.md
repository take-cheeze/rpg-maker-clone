# 63. Scale RPG2000 bitmap cache budgets with --render_fps

Date: 2026-08-27

## Status

Accepted

## Context

ADR 0047 sized `Scene::Map`'s seven named-graphic `LRUBitmapCache` budgets
(`mruby-rpg2k/mrblib/scene/map.rb`, `CHARSET_CACHE_BYTES` and siblings, 6.25 MB
combined at their base values) and the picture tone-effect cache
(`PICTURE_TONE_CACHE_MAX`, up to 16 same-size decoded bitmaps) as "a
conservative first cut, not a measured budget" — fixed constants, the same on
every target, because nothing in the engine distinguished "this is a
constrained device" from "this is a desktop" at the point those caches are
built.

ADR 0062 gave the engine exactly that signal for a different purpose:
`--render_fps` (threaded into mruby as the `RENDER_FPS` constant) exists
because a device may need to trade visible smoothness for less CPU/GPU/memory
work, and the PSP/Wio-class ports are the concrete targets it names. A game
launched with a low `--render_fps` is, by construction, running on hardware
where memory is also worth economizing — the same signal, unused for the
memory side of that trade.

## Decision

Add `RGSS::Graphics.render_fps` (`mruby-rgss/mrblib/lib.rb`), a thin reader
over the `RENDER_FPS` constant with the same "undefined means uncapped (60)"
fallback `--no_render_wait`'s own constant already uses, so game code never
needs to know whether it's running under the native binary or a host-side
check harness.

`RPG2k::Scene::Map#constrained_scale(base)` scales a byte budget or entry
count by the `render_fps`/60 ratio — `--render_fps=30` roughly halves it, `10`
roughly sixths it — floored at `base / CONSTRAINED_SCALE_FLOOR_DIVISOR` (8) so
a very low setting still leaves a small working set rather than none, and
returns `base` unchanged at the default 60 (a pure opt-in, no behaviour
change). Every `LRUBitmapCache.new` call in `#initialize` and the picture
tone-cache's eviction check in `#toned_picture_src` route their base constant
through it.

This is deliberately *only* a smaller eviction threshold, not a change to
what is cached or when: a scaled-down cache just evicts its least-recently-used
entry sooner, and anything evicted is transparently reloaded (and re-cached)
the next time its name comes up — the same cost the caches already pay on a
cold miss, just paid more often. No game logic, timing, or drawn output
changes at any setting, matching ADR 0062's own scope decision for
`--render_fps` itself.

## Consequences

- A PSP/Wio-class run launched at a low `--render_fps` now also holds a
  proportionally smaller working set of decoded named-graphic bitmaps and
  toned-picture variants, at the cost of more re-decodes on a cache miss —
  real RAM saved in exchange for CPU a constrained device already has less
  competition for once it is also rendering less often.
- An ordinary desktop run (`--render_fps=60`, the default) is byte-for-byte
  unaffected: `constrained_scale` returns `base` unchanged.
- `RGSS::Graphics.render_fps` is now available to any game-side Ruby code
  (mruby-rpg2k or otherwise) that wants to scale back optional, purely-visual
  or memory-costly work the same way — not something this ADR requires
  elsewhere, just a reusable hook now that it exists.
- The seven cache budgets and the tone-cache count remain "a conservative
  first cut, not a measured budget" per ADR 0047; real on-device measurement
  once a project actually runs on PSP hardware may still argue for different
  base values or a different floor, independent of this scaling mechanism.
