- **Boarding a boat, ship, or airship now honours a Change System BGM
  override for that vehicle's slot.** `Scene::Map#vehicle_bgm` used to always
  read the database's own `boat_music`/`ship_music`/`airship_music`, ignoring
  a Change System BGM (10660) override the event system already stashed on
  `Game::State#system_bgm` (slots 3/4/5, matching EasyRPG's
  `Game_System::sys_bgm` enum). It now resolves the override first and falls
  back to the database default — the same override-then-default idiom Change
  System SFX already uses. Covered by a new `scripts/rpg2k_scene_check.rb`
  check, confirmed to fail against the pre-fix code before the fix.
