- **Through Mode set on the player by a forced route now outlives the route,
  and Halt All Movement no longer silently clears it.** A forced player route
  (Set Move Route / Move Event targeting the hero) steps a disposable mirror
  character that carried Through Mode and nothing else, so it vanished the
  moment the route ended — by finishing normally or by being cancelled — and
  a fresh route always started its new mirror back at `through = false`.
  RPG_RT treats Through Mode as a standing property of the hero: it keeps
  affecting ordinary walking once the route stops, however that happened, and
  "Cancel All Designated Moves" aborts a route without unwinding that side
  effect (yado.tk). The flag now lives on the scene, seeds each new route
  mirror, and is checked by ordinary input-driven movement too. Covered by a
  new `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code before the fix. (A map event's own Through Mode, and a
  cancelled jump not un-landing, were both already correct — see
  `docs/TODO.md`.)
