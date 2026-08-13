- **RPG2000 games granted no starting items/gold and every "Call Event"
  targeting a common event silently no-op'd**, because
  `Game::CommonEvent.load` built each entry with a bare `key: value, ...`
  argument list passed straight to `Array#push`. On this project's mruby
  build that bare hash literal is consumed as keyword arguments rather than
  a single positional `Hash`, and since `Array#push` declares no keyword
  parameters the call silently degenerated to `list.push()` — no exception,
  but every common event vanished, so any `CALL_EVENT` targeting one
  resolved to `nil` and did nothing. Confirmed against the freeware game
  Nepheshel: its opening common event (which grants starting items and gold)
  never ran, leaving a permanently empty inventory; live tracing showed
  `CommonEvent.load` iterating 505 entries into a list of size 0 before the
  fix, and the common event's real commands resolving correctly after it.
  The same bare-hash-argument pattern also silently dropped every "Change
  Event Location" and "Trade Event Locations" command
  (`Game::Interpreter#do_change_event_location` /
  `#do_trade_event_locations`); both are fixed the same way. All three call
  sites now wrap the hash literal in explicit braces. A system-Ruby (MRI)
  unit test of the same loading logic did not reproduce this — MRI accepts
  the bare hash literal as a single positional argument for a method with no
  declared keywords — so this was only caught by driving the actual compiled
  engine.
