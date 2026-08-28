- **A battle animation's own per-frame sound effects now actually play**
  during a real battle round or a Show Battle Animation (11210/13260)
  command, instead of staying silent. The LCF `battle_anime` schema
  (`mruby-lcf/mrblib/schema.rb`, chunk 19's `timings` sub-table, field 2 `se`)
  has always decoded a `Sound` struct (file/volume/pitch/balance) alongside
  each timing's `frame`, and `Scene::Map#fire_animation_flashes` — the one
  place that walks a live animation's timings frame by frame — has always
  read that same struct's `flash_scope`/`screen_shaking` siblings there
  (fixed in earlier cycles) but never `se`. The only place an animation's own
  sound ever played was `Scene::Base#play_animation_se`, a deliberately
  narrower helper for the field item/skill menu's own success cue: a
  single-shot summary that plays the *first* timing across the whole
  animation with a real sound, once, before the animation itself even
  starts — not a substitute for a genuine battle round or a map-triggered
  Show Battle Animation sounding each frame's own timing as that frame
  arrives. `#fire_animation_flashes` now also plays a matching timing's `se`
  (blank/`"(OFF)"` treated as a no-op, mirroring `#play_animation_se`'s own
  convention for the identical field), unconditionally in both the map and
  battle-round context — a sound has no "screen vs target" split to gate on,
  unlike its flash/shake siblings. NOT independently confirmed against
  genuine RPG_RT under wine. Covered by three new `scripts/rpg2k_scene_check.rb`
  checks (a timing's `se` plays with volume/pitch/balance forwarded on the
  map path; a blank or `"(OFF)"` `se` plays nothing; the same `se` also plays
  on the battle-round path), confirmed to fail against the pre-fix code
  before the fix.
