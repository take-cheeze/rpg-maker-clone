- **RPG2003's battle-page Call Common Event command no longer swallows a
  dangling common event id with no trace.** A database shrink can leave the
  id it targets pointing at a common event that no longer exists — the
  "common event" case docs/TODO.md's runtime error catalog names, already
  reported for the map-side Call Event's own common-event mode but never
  wired up for this RPG2003-only battle sibling. `Interpreter
  #do_call_common_event` now logs a `[RPG2k] Call Common Event: common
  event #<id> not found` diagnostic when the resolver has nothing for the
  id, the same reported-not-invented shape every other entry in that
  catalog uses; the command was already a correct, harmless no-op either
  way (control simply continues past it), only the missing trace is new.
