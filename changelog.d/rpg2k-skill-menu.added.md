- RPG Maker 2000 main menu: the **Skill** command now opens a working skill
  screen (`Scene::SkillMenu`) — completing the main-menu set (Item / Skill /
  Equip / Status). It lists a caster's known field-usable normal skills with
  their SP cost (LEFT/RIGHT cycle the caster); casting a self- or all-ally skill
  applies at once, while a single-ally skill asks who to target. A cast spends the
  caster's SP and restores HP and/or SP (per the skill's affect-HP/SP flags) by
  the RPG2000 effect formula — `power + physical_rate * attack / 20 +
  magical_rate * spirit / 40`, confirmed against EasyRPG's `Algo::CalcSkillEffect`
  and computed deterministically for field use (battle adds the ± variance).
  SP cost is a fixed amount or a percentage of max SP (`sp_type`). The logic lives
  on `Game::Party` (`field_skills` / `skill_cost` / `can_cast?` / `skill_effect` /
  `cast_skill`) and is covered by five new checks in
  `scripts/rpg2k_logic_check.rb`; a cast that helps no one (target already full)
  spends nothing. Teleport / escape / switch skill types and the battle-time
  variance are later refinements.
