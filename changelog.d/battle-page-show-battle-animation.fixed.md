- **A Battle Event page's own Show Battle Animation (13260) now actually
  plays**, instead of the "wait until it finishes" flag being silently
  ignored — the same shape as the Parallel Process gap for the map command
  (11210), for the battle-page form. `Scene::Map#drive_battle_event_wait`'s
  dispatch had no `:animation` case, so a page blocked on one fell into the
  generic "release the request, resume unconditionally" `else` branch and
  was `#resume`d the very next frame — never built or drawn, regardless of
  the wait flag. Fixed by adding `when :animation then drive_map_animation(it)`,
  reusing the same shared renderer. That renderer needed generalizing
  further: the command's own `target` param is a **troop member index**, not
  a map target id, so a new `#start_battle_page_animation` (dispatched by
  `#start_map_animation` off the request's `battle:` flag) positions it via
  `#battle_animation_pixel` — the same enemy-sprite lookup a battle round's
  own animation already uses — instead of misreading it the map way. This
  also surfaced a latent bug in `#step_map_animation`'s finish branch: it
  used to read the `battle:` flag itself as a proxy for "no interpreter is
  waiting" (true only by coincidence for every prior caller), which would
  have silently swallowed the resume a battle-page's own waiting interpreter
  needs; now reads the real owner instead (`owner.resume if owner`).
  Covered by three new `scripts/rpg2k_scene_check.rb` checks (the page's
  interpreter actually parks on the `:animation` wait and stays held well
  past the pre-fix bug's next-frame resume; the sprite draws centred on the
  named troop member, not the ally screen-centre fallback; a flash_scope-1
  timing pulses only that member, not a bystander or the screen), confirmed
  to fail against the pre-fix code before the fix.
