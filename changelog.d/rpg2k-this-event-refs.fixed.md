- **"This event" (0 / 10005) now resolves on the read side of an event
  command.** The write-side commands (Move Event, Change Event Location, Flash
  Sprite) already reached the running event through the scene, but the commands
  the interpreter answers itself did not: a **Conditional Branch** orientation
  test on this event was always false, the **Control Variables** character
  operand read its position as 0, and a **Call Event** naming another page of
  this event silently did nothing. `Game::Interpreter#event_id` carries the
  running map event's id (nil for a common event or a battle page, where RPG_RT
  also has no "this event"), and every character reference goes through
  `#character_ref` before it is looked up. Measured on the real Nepheshel data,
  that is 223 of its 233 orientation branches, 239 of its 246 character-position
  reads and 17 of its 33 map-event calls.
