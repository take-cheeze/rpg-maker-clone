- **Title screen:** New Game and the headless single-slot Continue
  shortcut now fade the title music out over 800ms instead of cutting it
  instantly, matching RPG_RT's `Player::SetupNewGame`/`LoadSavegame` --
  Shutdown continues to leave the music playing through its own
  fade-out transition, unchanged.
