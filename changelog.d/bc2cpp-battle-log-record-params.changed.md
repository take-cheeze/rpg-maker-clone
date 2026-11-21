- **bc2cpp**: the battle scene's action-log entries are declared record
  parameters, checked where each name field is read, and a nil field's
  `to_s` compiles to the empty String, so the battle message lines build
  their names without owner calls.
