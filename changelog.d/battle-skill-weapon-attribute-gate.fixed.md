- **The in-battle skill menu now respects a skill's weapon-Attribute
  equip-gate, matching the field menu and Forced-AI.** `Game::Party
  #battle_skills`/`#battle_skill_command` never consulted `#can_cast?`/
  `#weapon_attribute_ready?` at all, unlike the field menu's `#cast_skill`
  (gated on `#can_cast?`) and a Forced-AI actor's own eligibility check
  (`Game::Battle#skill_ready?`, which already reuses `#can_cast?`) — so a
  player could select and land a weapon-Attribute skill in battle with no
  matching weapon equipped, full effect and all. `Scene::Map
  #confirm_battle_skill` now also checks `#weapon_attribute_ready?` alongside
  its existing SP-affordability check, Buzzing and staying on the list when
  either fails — mirroring the field menu's own "listed, but a cast attempt
  quietly fails" pattern (this codebase never renders a greyed-out state for
  either menu) rather than excluding the skill from the list. An
  item-triggered skill cast still bypasses the gate entirely, unaffected.
  Covered by new `scripts/rpg2k_logic_check.rb` and `scripts/
  rpg2k_scene_check.rb` checks.
