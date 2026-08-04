- **Show Picture** (11110), **Move Picture** (11120) and **Erase Picture**
  (11130) event commands are now handled. A `Game::Pictures` layer on
  `Game::State` holds each numbered picture's graphic name, screen (or map-fixed)
  position, magnification, top transparency, red/green/blue/saturation colour
  tone and rotation/wave effect — all read from the RPG2000 parameter layout,
  with the position optionally taken from variables. **Move Picture** tweens
  those attributes toward new values over its duration (an integer-division tween
  like the screen tint, so it stays float-free for the mruby build) and, when its
  wait flag is set, pauses the interpreter via a new `:picture` wait that
  `Scene::Map` resumes once no picture is moving; the scene advances the layer
  every frame. **Erase Picture** drops one. Like the tint/flash overlays this is
  the Ruby-half model only — actually compositing the picture bitmap
  (magnify/rotate/tone blit with per-picture alpha) is native (C++) renderer work
  still to come, so it does not yet change what is drawn. `analyze_game.rb` marks
  11110/11120/11130 (and the already-wired Change Equipment 10440) implemented.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
