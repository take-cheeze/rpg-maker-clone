- **A battler carrying any state at all — not just one flagged "Avoid
  Attacks" or "Reflect Magic" (RPG2003) — no longer dodges every basic
  attack or reflects every Skill.** `Game::Battle#evades_all_physical?` and
  `#reflects_magic?` scanned a battler's states through `#state_field`, a
  helper meant for numeric fields whose `|| 0` fallback reads an unset
  boolean as the integer `0` — which is truthy in Ruby, so `.any? { ... }`
  answered true for any inflicted state, flagged or not. Both now use
  `#state_flag`, the helper `#skill_sealed?` already used correctly for the
  same kind of field.
