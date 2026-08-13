- **A battle Item command's ally-target picker now respects the item's
  使用可能キャラ (`actor_set`) restriction**, instead of always offering
  every living party member. `Game::Party#item_usable_by?` already gated a
  restricted item's *effect* on the field menu (`use_medicine`'s per-target
  `next if ... !item_usable_by?`) and greyed it out there
  (`item_effective?`), but the battle screen's own single-target picker
  (`Scene::Map#draw_battle_ally_target` / `#drive_battle_ally_target`) read
  straight off `#living_allies` with no restriction awareness at all, so a
  player could pick — and actually heal — a party member the item is not
  usable on, something the field menu already refused to let happen. Fixed
  with a new `Scene::Map#battle_ally_targets`, which narrows the candidate
  list by `item_usable_by?` whenever the pending action is a Battle Item
  (a pending skill is untouched, since `actor_set` only ever gates
  equipment/items); `Game::Party#battle_item_command` itself stays pure
  arithmetic, unchanged, since the gate is about which target may be offered
  at all, not what the formula computes once one legitimately is. Covered by
  a new `scripts/rpg2k_scene_check.rb` check (a two-actor party where the
  item excludes the second actor: the picker offers only the first, and
  moving the cursor has nowhere to go), confirmed to fail against the
  pre-fix code before the fix.
