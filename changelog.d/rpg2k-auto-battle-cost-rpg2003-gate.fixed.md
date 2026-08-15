- **A Forced-AI actor's auto-battle skill ranking no longer overcharges a
  skill's cost with an RPG2003-only formula on an RPG2000 database.**
  Confirmed against EasyRPG Player's source: the percent-cost formula used
  when ranking a skill against a plain Attack is gated on the project being
  RPG2003, matching the same gate this codebase already applies to the SP
  actually charged. The ranking-only cost term was missing that gate, so a
  stray database byte could inflate a skill's apparent cost 5x and change
  which action a Forced-AI actor picks.
