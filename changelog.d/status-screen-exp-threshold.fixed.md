- **Status screen:** The "Next" EXP figure now shows the absolute EXP
  threshold for the next level -- matching RPG_RT's own
  `Window_ActorStatus::DrawStatus`/`GetNextExpString` -- instead of the
  remaining delta to reach it (e.g. "2000" rather than "766" for an actor
  1234 EXP into a 2000 threshold).
