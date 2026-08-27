# 62. Cap render rate independently of game-logic rate

Date: 2026-08-27

## Status

Accepted

## Context

`RGSS::Graphics.update` (`mruby-rgss/src/lib.cxx`, `gfx_update`) is the single
per-frame pump for every maker: one call advances `Graphics.frame_count`,
drives input, runs the interpreter's own timed things (walk cycles, message
reveal, `Wait`), reorders/invalidates the LVGL display tree and then calls
`lv_timer_handler`/`lv_task_handler` to actually redraw and present, before
sleeping to the next 1/60s deadline (see ADR 21's frame-pacing note in the
same function). Logic and rendering are the same call — there is no separate
fixed-timestep-simulation-vs-variable-render split the way many engines have.

That coupling is exactly why lowering the frame rate for constrained hardware
(older phones, the PSP/Wio Terminal ports, battery saving in general) is not a
free choice: naively pacing the whole loop to, say, 30Hz would also halve
every frame_count-driven timer, since nothing here reads a wall-clock delta —
speeds are expressed in frames. A "low FPS mode" that changes how fast the
game plays is a different, much larger feature (it would need every timed
thing ported to a delta-time model) and was explicitly not what was wanted:
the ask was to cut rendering cost for devices that need it, without changing
game feel.

The `docs/android-perf-followups.md` / `app/android/README.md` work already
cuts rendering cost by skipping redraw *whose output would not change*
(`Scene::Map`'s per-layer dirty tracking, `Sprite#opacity=`/`x=`/`y=` no-oping
on an unchanged value). That is complementary but orthogonal: it saves work
when nothing moved, and does nothing when something did — walking across a
panorama map, or standing in a busy battle, still redraws every single frame.
There was no existing lever for "redraw less often than every frame,
regardless of what's on screen," which is what a device that is simply too
slow (or wants to save battery) actually needs.

## Decision

Add `--render_fps=N` (`src/main.cxx`, threaded into mruby as the `RENDER_FPS`
constant the same way `--no_render_wait` threads `NO_RENDER_WAIT`). `gfx_update`
gates only the render-heavy tail of the frame — z-reorder, bitmap-dirty
invalidation and the `lv_timer_handler`/`lv_task_handler` draw/present — behind
a `render_due()` check; everything before it (input poll via `Input.update`,
`Graphics.frame_count`, the interpreter's own per-frame work) and the 1/60s
wall-clock pacing sleep after it are untouched. So the game still advances,
times and paces at 60 logical frames a second at every `--render_fps` setting;
only how often the screen actually repaints changes.

`render_due()` spreads the rendered frames evenly across each 60-call window
with the same accumulator technique the pacing sleep already uses for its
17/17/16ms step (`g_period_acc`) rather than rendering in bursts: `--render_fps
30` renders every other call, `15` every fourth, `10` every sixth. A frame that
is skipped does not clear the z/bitmap-dirty flags it would otherwise have
cleared, so the next frame that does render still picks up everything that
changed while it waited — nothing is silently dropped, just deferred to the
next visible repaint. Default is `60` (render every frame; the flag is a pure
opt-in with no behaviour change).

Deliberately scoped to *redraw*, not input latency or logic responsiveness: a
skipped frame still polls input and runs the interpreter, so `Input.update`
still sees every real transition — only the visible update lags by up to
`60/render_fps - 1` frames, same trade-off a display's own refresh cap would
make.

## Consequences

- A constrained device (or a player who wants to save battery) gets a real
  CPU/GPU/bandwidth reduction proportional to how much of the frame's cost was
  actually in `gfx.zorder`/`gfx.invalidate`/`gfx.lvgl` (see `--profile`'s
  section breakdown) — `docs/profiling.md`'s baseline numbers are the ones to
  compare against on a given target.
- Game speed, save timing and any script relying on `Graphics.frame_count`
  are unaffected at any setting — there is no game-visible difference besides
  the screen repainting less often, which is the trade-off asked for.
- Android's own on-screen virtual pad (`src/android_vpad_ui.cxx`) hangs its
  press-highlight redraw off the same `lv_timer_handler` pump, so at a low
  `--render_fps` its visual feedback lags by the same skipped frames as the
  game picture. This was accepted rather than special-cased, since it is a
  visual-only overlay and the whole point of the flag is fewer visual
  updates per second.
- This is a coarser, always-on lever than the existing per-object dirty
  skipping (`Scene::Map`, `Sprite#opacity=`/`x=`/`y=`); the two compose —
  dirty skipping still avoids redundant work on the frames that do render.
- A future genuine delta-time mode (game logic itself pacing to a lower rate)
  remains a separate, much larger change if ever wanted; this ADR only covers
  the redraw-rate cap.
