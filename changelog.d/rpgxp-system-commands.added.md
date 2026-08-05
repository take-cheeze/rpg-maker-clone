- The RPG Maker XP interpreter handles the **Game_System** event commands. A new
  `Game::System` (saved with the rest of the state) carries what they write:
  **Change Save / Menu Access** (134/135) and **Change Encounter** (136), stored
  with RMXP's `*_disabled` polarity; **Change Battle BGM / Battle End ME**
  (132/133), held as an override that stays `nil` until a command sets one so a
  reader falls back to the database's own — an *empty* name is a different,
  real setting (silence); and **Change Text Options** (104), whose position and
  frame `Scene::Map` applies when it opens a message box. **Fade Out BGM / BGS**
  (242/246) fade in milliseconds without pausing the list, as `command_242` does.
  **Change Actor Graphic** (322) swaps an actor's charset and battler, and
  `State#leader` answers with the live `Game::Actor`, so the map draws the
  graphic the event set rather than the one the editor shipped.
