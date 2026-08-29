- **Enemy Encounter** battles now play the victory fanfare. Winning a fight
  used to jump straight to the "Victory! / EXP gained" result window with
  whatever track the battle itself had playing still running; RPG_RT instead
  swaps in the System's `battle_end_music` (Change System BGM slot 1) the
  moment the result screen opens, and only brings the pre-battle field /
  vehicle track back once the player dismisses it. `Scene::Map#victory_bgm`
  mirrors the existing `#battle_bgm` override-then-default lookup (a Change
  System BGM slot-1 override wins over the database default), and
  `#play_victory_bgm` is called from `#enter_battle_result` on a win, right
  alongside the two slot-0/3-5 lookups `#battle_bgm`/`#vehicle_bgm` already
  had and the slot-6 one `Scene::GameOver` already had — victory (slot 1) was
  the one remaining slot in RPG_RT's own system-BGM array (ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine) that Change System BGM could set but nothing ever
  played. Covered by two new `scripts/rpg2k_scene_check.rb`
  checks (the database `battle_end_music` plays over the result screen and
  the field BGM resumes only once it is dismissed; a Change System BGM
  override on slot 1 beats the database default), both confirmed to fail
  against the pre-fix code before the fix.
