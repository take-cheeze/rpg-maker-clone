- **Walking into an event-touch event now sets it off.** RPG_RT tests the two
  touch triggers as one set on every player-side path (EasyRPG's
  `{Trigger_touched, Trigger_collision}` in `Game_Player::Update` /
  `UpdateMovement`), so the asymmetry is not the one the trigger names suggest:
  an **event touch** (2) fires whether it walked into the party or the party
  walked into it, while a **player touch** (1) fires only on the party's own
  move — the event side checks trigger 2 alone. This build only accepted
  trigger 1 when the party moved, so a trigger-2 event could be set off solely
  by walking into *you*. Nepheshel has 9,637 trigger-2 pages (6,912 carrying
  commands) — its roaming monsters — and 3,972 of them are **stationary**, which
  can never walk into anything: 1,259 of those carry commands, so that content
  could not be reached at all.
