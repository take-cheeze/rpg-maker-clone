- **Events:** a Simulated Attack command naming an invalid actor id (an
  authoring mistake, or a variable-actor mode's own variable gone stale)
  no longer zeroes its "store damage" result variable, matching RPG_RT --
  previously a target-less hit silently cleared whatever value the
  variable already held.
