- **Four more of `Scene::Map`'s guaranteed-every-frame `@events.each { }`
  loops no longer allocate a Proc/closure just to drive themselves.**
  Continuing the `step_parallels` fix from the same round:
  `#record_map_event_positions`, `#step_events` (the normal-gameplay
  autonomous/custom-route movement pass), `#animate_events` and
  `#update_sprite_flashes`'s per-event flash decay all ran a one-line
  `@events.each { |e| ... }` unconditionally (or near-unconditionally) every
  single frame — in mruby that allocates a real Proc plus its closure env on
  every call, confirmed by measurement. Rewritten as plain `while` loops.

  Unlike `#step_parallels`, none of these four need a defensive `#dup` of
  `@events` first: `#step_event` only *sets up* the interpreter via
  `#start_event`, it never drives it, so no command — Erase Event included —
  can run synchronously from inside the loop to shrink `@events` mid-iteration;
  `#animate_event` and `#tick_flash` only touch the one event hash / flash
  hash they are handed, never `@events` itself. (`#step_parallels` differs
  because a Parallel Process's own commands, unlike movement/animation
  bookkeeping, really do run inline via `it.update`, and one of them can be
  Erase Event on a *different* parallel's own event — see that fix's own
  comment.)

  Measured with the same temporary per-frame instrumentation used for this
  round's other fixes (reverted before commit), clean A/B on the identical
  deterministic Nepheshel run: **Proc allocations 43.6 → 40.6 per frame, env
  32.6 → 29.6** — exactly three of each removed, matching the three
  unconditionally-running loops exactly (`#record_map_event_positions`'s own
  Array-reuse fix from earlier in this round already accounts for its Array
  count, unaffected by this purely mechanical loop change).

  Verified against `scripts/rpg2k_command_soak.rb` (368,332 real event
  commands across both Nepheshel variants) and `scripts/rpg2k_scene_check.rb`
  (932 checks, ticks the real `Scene::Map` update path these four loops sit
  in), plus the rest of the RPG2000 logic/render checks — all pass,
  unchanged.
