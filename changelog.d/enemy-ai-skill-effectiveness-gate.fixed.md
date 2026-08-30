- An enemy's own **AI action pattern** no longer offers a self/ally-scope
  skill that could not possibly help anyone. `Game::Battle#choose_enemy_
  action`'s weighted draw gated a skill action only on affordability and
  silence (`#enemy_action_valid?`/`#enemy_skill_ready?`), with nothing
  checking whether casting it would do anything — so a pure state-cure
  action ("Cure Poison", say) with no target on the caster's own troop
  actually carrying that state could still dominate the draw purely off
  its own rating, casting a visible no-op turn after turn instead of
  yielding to whatever else the pattern offered. Fixed with a new
  `Game::Party#skill_helps_troop?`, ported from a reference implementation's
  own enemy-AI skill-effectiveness check (not independently confirmed
  against genuine RPG_RT under wine) and reusing the same no-op rule the
  field menu's own
  `#skill_effective?` already applies to grey out a wasted cast, consulted
  in a separate pass mirroring that same source's own two-pass structure: an
  ineffective skill's raw rating still counts toward the round's
  `max_prio` (so it still crowds out other, lower-rated candidates exactly
  as if it were still in the running), only its own draw is zeroed. A
  party-scope skill (aimed at the player side) is never filtered this way,
  matching real RPG_RT; nor is an HP/SP/stat-affecting skill, which the
  real engine always considers worth trying against a live target
  regardless of its actual HP/SP level.
