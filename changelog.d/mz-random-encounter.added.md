- **MZ starts a battle nobody asked for.** `--mz_encounter_test`
  (`MZ_MODE=encounter`) transfers to the test bed's second map and simply walks
  until a random encounter fights, asserting one fired and that the troop came
  from that map's encounter list. Every other battle here is started by a Battle
  Processing command — a game telling the engine to fight — while an encounter
  is the engine deciding to, through `Game_Player.updateEncounterCount` and
  `executeEncounter` with no event involved. The bed's maps carried no encounter
  list at all, so the path had never run. The encounters are authored on the
  second map deliberately: the move probe walks on the first, and a fight
  breaking out mid-probe would derail it.
