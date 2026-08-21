- **Battle:** a status that can never auto-release on its own
  (`auto_release_prob` 0 -- a typical "must be cured" ailment) now still
  burns its RNG draw every turn once eligible, matching RPG_RT -- the
  guaranteed-fail roll was previously skipped outright, silently drifting
  this build's shared RNG stream out of sync with a real seeded run for
  the rest of the fight.
