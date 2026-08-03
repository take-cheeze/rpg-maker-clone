- RPG Maker **XP** *Set Move Route* (209) and *Input Number* (103) event
  commands. `RPGXP::Game::Interpreter` now queues the `RPG::MoveRoute` packed
  into a Set Move Route command for its target (the player `-1`, "this event"
  `0`, or a map event id), resolving "this event" to the running event and
  dropping requests with no context or no route; unlike a message / wait /
  teleport, a move route does not suspend the interpreter, so `Scene::Map`
  drains the queue after each step (`take_move_route_requests`) and drives the
  target along the route in the background. A forced route overrides an event's
  page movement until it finishes (paced by the event's move frequency) and does
  not survive a map change; a forced *player* route mirrors a `Game::Character`,
  snaps tile-to-tile and suppresses input while active. *Input Number* suspends
  the interpreter with a `:number` request; `Scene::Map` opens a digit-entry
  widget backed by a pure, testable `RPGXP::Game::NumberInput` (fixed digit
  count with a movable cursor, up/down wrapping each digit 0–9) and
  `resume_number` stores the entered value into the target variable. Covered by
  new `mruby-rpgxp/test` cases (move-route queueing / target resolution, the
  input-number request + result, and the number-input digit model).
