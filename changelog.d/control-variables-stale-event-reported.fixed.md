- **Control Variables' Character operand now reports a stale event target**
  ("This Event" used inside a Common Event, or a map event id absent on the
  current map) as a `[RPG2k] Control Variables: ...` diagnostic instead of
  silently reading `0`, matching the reported-not-invented pattern already
  used for Call Event/Enemy Encounter/Transfer Player. `Interpreter
  #event_operand`/`#screen_operand` (`mruby-rpg2k/mrblib/interpreter.rb`).
  Covered by four new `scripts/rpg2k_logic_check.rb` checks.
