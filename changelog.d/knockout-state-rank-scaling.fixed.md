- **Battle:** an instant-death ("Knockout"/戦闘不能) infliction from a skill
  or weapon is now scaled by the target's own A-E state resistance rank
  (and any anti-death equipment) exactly like every other status, matching
  RPG_RT's own `GetStateProbability`. Previously this codebase exempted
  Knockout from rank scaling entirely, based on an uncited fan-site claim --
  so a target with rank-E ("immune") Knockout resistance, or full anti-death
  gear, could still be instant-killed at the skill's raw occurrence rate.
