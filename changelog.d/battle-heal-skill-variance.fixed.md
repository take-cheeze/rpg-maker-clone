- **A battle Skill's HP/SP recovery now spreads by the skill's own variance
  too**, matching a damage skill's own spread. RPG2000's
  `Algo::VarianceAdjustEffect` is one function applied to whichever signed
  effect `Algo::CalcSkillEffect` produced — a Cure spell's heal wobbles the
  same way a Fire spell's damage does — but `Game::Party#battle_skill_command`
  only attached a `variance:` figure to the attack branch (enemy-scope
  skills), and `Game::Battle#apply_skill_hit`'s recovery branch never read one
  even when it had it: every ally-scope skill in a fight — self, single-ally
  and all-ally alike — restored exactly its deterministic base amount, round
  after round, while the identical field/menu cast was *supposed* to be the
  only deterministic path (its own doc comment already said so: "battle
  applies a +/- variance, but field/menu use does not"). Both are fixed:
  `battle_skill_command`'s heal branch now reports `variance: skill_variance
  (sk)` alongside its `hp`/`mp`, and `apply_skill_hit` spreads `hp` and `mp`
  independently through the same `#varied` helper the attack branch already
  uses, only when the fight has variance enabled. An item's fixed effect is
  untouched — items carry no `variance` field, so `apply_skill_hit`'s new
  spread is a no-op there, and an ordinary attack's own variance path is
  unchanged. Covered by three new `scripts/rpg2k_logic_check.rb` checks (a
  seeded fight's ally-scope heal lands a spread of values within the same
  `base`/`variance` range the equivalent attack-scope skill spreads within; a
  fight with variance off heals for the exact deterministic base amount; and
  `battle_skill_command`'s heal branch reports the skill's own variance
  rather than dropping it), confirmed to fail against the pre-fix code (a
  constant heal, a missing `variance` key) before the fix.
