- `Game::State#to_lsd`/`.from_lsd` now round-trip the vehicle/battle BGM
  restore point (chunk 101 fields 76/77, liblcf's own `before_vehicle_music`/
  `before_battle_music`) through a genuine Save/Continue. Previously tracked
  only as a transient `Scene::Map` instance variable
  (`#restore_pre_vehicle_bgm`/`#restore_pre_battle_bgm`'s own stash), so a
  save taken mid-vehicle-ride or mid-battle and then continued would resume
  whatever was already playing rather than remembering the field/vehicle
  track to restore on disembark or after the fight — now promoted onto
  `Game::State` (`#pre_vehicle_bgm`/`#pre_battle_bgm`) and persisted through
  both save formats. Confirmed against a genuine kk1.12 save under wine
  (taken outside any vehicle/battle): both fields are always present, "(OFF)"
  — RPG_RT's own placeholder — standing in for "nothing to restore" rather
  than the field going absent.
- Fixed `Game::State.bgm_from_chunk` (the save-side BGM decoder) to treat the
  literal file name `"(OFF)"` the same as an absent or blank one — matching
  `#play_bgm_or_stop`'s existing fix for live playback. A Change System BGM
  override (or either restore point above) explicitly left at `"(OFF)"`
  previously decoded as a genuine request to play a file literally named
  `"(OFF)"` instead of "nothing here, use whatever otherwise applies".
