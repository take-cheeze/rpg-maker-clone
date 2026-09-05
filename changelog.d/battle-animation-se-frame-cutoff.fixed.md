- **A battle animation's own per-frame sound effect stops sounding once its
  timing's `frame` reaches 21, matching genuine RPG_RT.exe.**
  `Scene::Map#fire_animation_flashes` played a timing's `se` for any frame at
  all, with no upper bound. Confirmed against genuine RPG_RT.exe under wine:
  a synthetic animation with an early (frame 5, a long ~3.06s sound) and a
  late (frame 21, a short ~0.15s, acoustically distinct sound) se cue, cast
  by a custom enemy every round, showed only the frame-5 cue's own envelope
  in a PulseAudio capture of several real battle rounds — never a second
  burst. A same-pipeline control fixture with the frame-21 cue removed
  entirely produced a statistically indistinguishable capture (ratio ~1.0
  across the whole ~3.3s decay), ruling out the alternative explanation that
  the frame-21 cue was simply too quiet or too short to show up. Fixed by
  skipping a timing's own `se` once its `frame` exceeds the new
  `ANIM_SE_MAX_FRAME` (20) constant; flash_scope/screen_shaking handling is
  untouched (not tested by this capture). Covered by two new
  `scripts/rpg2k_scene_check.rb` checks (frame 20 still sounds, frame 21
  never does, on both the map and battle-round paths), confirmed to fail
  against the pre-fix code.
