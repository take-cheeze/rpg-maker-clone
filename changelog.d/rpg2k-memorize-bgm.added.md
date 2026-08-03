- **Memorize BGM** (11530) and **Play Memorized BGM** (11540) event commands are
  now handled — the "BGM stack" RPG2000 games use to duck to a fanfare and then
  return to the field music. `Game::State` tracks the currently-playing BGM
  (recorded whenever Play BGM runs) and the stash that Memorize BGM copies it
  into; Play Memorized BGM restores that stash and makes it current again. Both
  the current and memorized BGM are persisted in the save. Playback resumes from
  the start rather than the stored position (the SDL_mixer backend cannot seek).
  Covered by new checks in `scripts/rpg2k_logic_check.rb`.
