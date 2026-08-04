- `Game::Actor` now tracks the **skills it knows**. New Game seeds them from the
  database growth table (every skill whose learn-level is at or below the actor's
  level; levelling learns more and never un-learns), Continue restores the saved
  skill set (chunk 108 field 52), and the **actor "knows skill" conditional
  branch** (type 5, sub 4) is modelled via `Actor#knows_skill?`. Validated
  against a real save: the skills learnt up to each actor's level match its saved
  skill list exactly (e.g. actor 3 at L5 → {25, 27, 32}). Covered by the logic
  and save-load checks.
