- **Set Move Route ("Move Event") targeting a genuinely nonexistent event id
  now logs a `[RPG2k] Move Event: ...` diagnostic**, instead of silently
  dropping the request with no trace. Behaviour is unchanged (still a
  dropped, non-freezing no-op, distinct from the existing hard-freeze on a
  real-but-currently-hidden target) -- this closes the last of the four
  "invalid event ID" causes the runtime-error catalog named as still
  unreported (Call Event, Enemy Encounter and Control Variables' Character
  operand already had their own equivalents). Covered by extending the
  existing `scripts/rpg2k_scene_check.rb` check for this exact case.
