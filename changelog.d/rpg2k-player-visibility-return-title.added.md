- Two more RPG2000 event commands are now handled. **Set Transparent Flag /
  Change Player Visibility** (11310) toggles a `player_transparent` flag on
  `Game::State`; `Scene::Map` hides or shows the party leader's map sprite each
  frame accordingly (combined with the leader graphic's own semi-transparent
  flag), and the flag is persisted through Save / Continue. The polarity
  (param0 non-zero = transparent) follows a reference implementation's own
  polarity (not independently confirmed against genuine RPG_RT under wine).
  **Return to Title Screen** (12510)
  suspends on a `:return_title` request the scene answers by stopping the event
  and calling the app's `return_to_title`, tearing the play scenes down and
  showing a fresh title. Player Visibility was one of the two event-command gaps
  `docs/rpg2000-sample-analysis.md` flagged in the real sample games, leaving
  Pan Screen (11060) as the last presentation gap there. Covered by new checks
  in `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
