- RPG Maker 2000: corrected three event-command opcodes that did not match
  liblcf's `Code` enum, so the commands are now recognised in real game data.
  **Change Equipment** was dispatched on 10440, which is actually **Change
  Skills** — it moves to 10450; **Game Over** was 12520 and is 12420. The same
  106xx shift in `scripts/analyze_game.rb`'s label table (which named 10610
  "ChangeVehicleGraphic" and reported the real 10660 / 10690 as "unknown") is
  fixed too, and that tool's coverage list is now read out of
  `Game::Interpreter::Cmd` instead of a hand-kept duplicate, so its
  implemented / feature-gap figures cannot drift as commands land.
