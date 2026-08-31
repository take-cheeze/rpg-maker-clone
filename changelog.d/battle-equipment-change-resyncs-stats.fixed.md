- **A mid-battle Change Equipment event command now actually changes that
  fighter's own battle math, not just the persisted Actor.** The fighting
  `Combatant`'s `atk`/`def`/`spi`/`agi` were a one-shot snapshot taken once
  at battle start (`Combatant.from_actor`), so equipping a stronger weapon or
  armor mid-fight updated the party member's stats everywhere else but left
  every damage roll, hit-rate check and stat-mod clamp for the rest of that
  fight computed against the stale pre-change numbers. `#sync_allies_from_party`
  (already re-run every round, and before every action) now also refreshes
  those four fields from the live actor each time it runs; current HP/MP are
  left untouched, since those are the fight's own live state rather than a
  re-derivable stat.
