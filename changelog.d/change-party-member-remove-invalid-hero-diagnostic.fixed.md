- **Event commands:** Change Party Member's "Remove" branch now reports the
  same `[RPG2k] actor #<id> could not be built: ...` diagnostic Add already
  does when the targeted hero id is a genuinely dangling reference (a
  database shrink, not merely "not currently in the party") -- closing the
  "invalid hero" case of the runtime error catalog, which Add (and every
  other actor-id-consuming command, via the shared `Game::Actors#[]`
  lookup) already covered. The check is done without instantiating (and so
  without enrolling into the save data) the actor, unlike Add's own
  lookup, which legitimately needs to build it.
