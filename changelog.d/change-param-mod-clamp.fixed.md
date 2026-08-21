- **Actors:** the Change Parameters event command and Seed items now clamp
  their running stat modifier to +/-999 on every application, matching
  RPG_RT's own `SetBaseAtk`/`SetBaseDef`/`SetBaseSpi`/`SetBaseAgi`/
  `SetBaseMaxHp`/`SetBaseMaxSp`. Previously an unbounded shadow total could
  accumulate underneath the displayed 1..999/1..9999 clamp, so a deep
  debuff followed by a partial recovery stayed pinned at the old value
  until the raw total genuinely climbed all the way back -- real RPG_RT
  reacts to the very next partial raise instead.
