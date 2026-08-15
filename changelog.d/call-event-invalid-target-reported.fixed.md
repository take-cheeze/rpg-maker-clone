- **Call Event now reports an unresolved target** (a stale/missing map event
  id, a stale page number, "This Event" used inside a Common Event, or an
  unknown common-event id) as a `[RPG2k] Call Event: ...` diagnostic instead
  of silently resolving to nothing, matching the reported-not-invented
  pattern already used elsewhere (Toggle Fullscreen, Call Common Event).
  `Interpreter#resolve_call`/`#map_event_call`
  (`mruby-rpg2k/mrblib/interpreter.rb`). Covered by four new
  `scripts/rpg2k_logic_check.rb` checks.
