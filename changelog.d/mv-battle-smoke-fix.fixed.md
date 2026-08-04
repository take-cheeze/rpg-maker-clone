- MV battle smoke (`--mv_battle_test`) now actually enters `Scene_Battle`.
  It previously injected a bare `SceneManager.push(Scene_Battle)` from outside
  the scene loop, which deadlocked: `Scene_Map.stop` starts the encounter-effect
  intro, but that intro only advances while the map is inactive, so an
  out-of-loop push left the map active with the effect frozen and the pending
  battle never applied — the capture just showed the map. It now runs a real
  "Battle Processing" event command (code 301) through the map interpreter, the
  same path an actual game uses, and logs `[MV-BTL] reached_battle=<bool>`. The
  CI step was pointed at the Lunatic-Core bed (which ships battlers and a
  battleback), so the captured frame shows a real battle (enemy + battle log)
  instead of the art-less sample's near-black screen. Verified against a native
  build: `[MV] scene: Scene_Battle` with a rendered "Fighter emerged!" frame.
