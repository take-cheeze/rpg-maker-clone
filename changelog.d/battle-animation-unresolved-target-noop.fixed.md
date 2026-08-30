- **Show Battle Animation event command:** a target that doesn't resolve --
  "This Event" fired from a common event's own Parallel Process, or a
  specific event id the map has no character for -- no longer draws on the
  player instead. Matches RPG_RT's own Show Battle Animation command
  handling, ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine, which no-ops the entire
  command (including a "Whole screen" target) whenever the named event
  can't be resolved. A
  "wait until it finishes" request on such a target now also falls
  straight through to the next command the same tick, instead of stalling
  for the animation's own real duration.
