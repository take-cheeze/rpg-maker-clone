- RPG Maker 2000: an item or piece of gear reserved for a **named character**
  (the `actor_set` / `actor_set_size` fields, parsed but never consulted
  before) is now actually restricted to them — it could previously be
  equipped or used by anyone. `Party#item_usable_by?(it, actor_id)` reads the
  restriction (an entry the array is too short to reach defaults to allowed,
  matching a reference implementation's item-usability check — not
  independently confirmed against genuine RPG_RT under wine), wired into
  `item_effective?` (menu grey-out), `use_medicine` / `use_skill_book` /
  `use_seed` / `use_special_item` (the effect itself — `use_medicine` checks
  it per target so a restricted member is skipped even under an all-party
  scope), `equip_candidates` / `equip_candidate_for?` (the equip menu), and
  the **Change Equipment** event command (10450), which the same reference
  implementation gates through the identical check. Left open: the battle
  screen's ally-target picker for a restricted item still lists every living
  ally — noted in `docs/TODO.md` as a follow-up rather than silently
  inconsistent. Covered by new `scripts/rpg2k_logic_check.rb` checks.
