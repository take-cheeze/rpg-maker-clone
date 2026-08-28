- **`Scene::Map`'s per-frame draw path allocates fewer throwaway objects.**
  Follow-up to the `skip_to` array-hoisting fix, driven by the same
  `RGSS::Profiler.stats[:object_types]` per-type breakdown, this time aimed at
  the render side rather than the interpreter:
  - `#events_dirty?`/the tile-cache redraw's per-event signature check used to
    rebuild an Array-of-Arrays (one outer Array plus one signature tuple per
    on-screen event, each tuple itself built from two more arrays returned by
    `Game::EventGraphic.frame` and `#event_pixel`) every time it ran, whether
    or not anything had actually changed. Replaced with `#store_event_draw_sig`,
    which writes each event's ten signature fields as scalars into a reused
    flat buffer and diffs them in place — same positional dirty semantics
    (a page rebuild that resizes or reorders `@events` still reads as dirty),
    zero per-event allocation. `Game::EventGraphic.frame` and `#event_pixel`
    gained `frame_dir`/`frame_col` and `event_pixel_x`/`event_pixel_y` scalar
    siblings so the signature check can ask for just the two numbers it needs
    instead of a pair wrapped in a throwaway Array; the original array-returning
    methods are unchanged for their other callers. The redundant recompute after
    `#draw_layers` redraws (previously always re-ran the full check even when
    `#events_dirty?` had just computed the identical values) is now skipped
    whenever `#events_dirty?` already ran that frame.
  - `#render` and `#camera_position` both computed `#player_pixel` (one more
    Array) every frame; `#camera_position` now takes the already-known
    `px, py` as optional arguments instead of recomputing them.
  - `#draw_timer`'s `2.times { |id| draw_one_timer(id, battle) }` allocated a
    Proc (and its closure env) every frame to call a two-line method twice;
    replaced with two direct calls.

  Measured with a temporary per-frame instrumentation pass (`RGSS::Profiler`'s
  cumulative alloc counters, sampled every 120 frames) against the same
  deterministic 26s Nepheshel run, comparing the exact same input/timing with
  and without these changes: **Array allocations 86.2 → 80.2 per frame, Proc
  42.6 → 41.6, env 31.6 → 30.6** on this particular map's on-screen event count
  — the `#events_dirty?` rewrite scales with the number of on-screen events, so
  the win grows on more populated maps. Verified against
  `scripts/rpg2k_command_soak.rb` (184,166 real event commands from Nepheshel),
  `scripts/rpg2k_scene_check.rb` (which ticks the real `Scene::Map` render/update
  path), and the rest of the RPG2000 logic/render checks, all unaffected — every
  frame still redraws the exact same pixels; only what gets allocated to decide
  that changed.
