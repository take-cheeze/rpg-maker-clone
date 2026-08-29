- **A Forced-AI actor's auto-battle skill ranking no longer overcharges a
  skill's cost with an RPG2003-only formula on an RPG2000 database.**
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: the percent-cost formula used
  when ranking a skill against a plain Attack is gated on the project being
  RPG2003, matching the same gate this codebase already applies to the SP
  actually charged. The ranking-only cost term was missing that gate, so a
  stray database byte could inflate a skill's apparent cost 5x and change
  which action a Forced-AI actor picks.
