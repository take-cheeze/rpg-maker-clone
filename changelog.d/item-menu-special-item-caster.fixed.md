- **A self/all-ally scope special item (type 9, 特殊) can be used from the
  item menu now**, instead of silently reporting "It had no effect." every
  time. `Scene::ItemMenu#choose_item` routed such an item through the same
  no-prompt path an all-ally medicine uses, calling `apply_item(id, nil)` —
  which works for a medicine (`Game::Party#use_medicine`'s all-ally branch
  never reads that argument, pulling the whole party off `@actors` instead)
  but not for a special item: `#use_special_item` treats its `actor`
  argument as the *caster* it casts the invoked skill from, and refuses
  outright when it is `nil` (`return [] unless actor`) before the skill's
  own scope is ever consulted. Fixed by passing `@state.party.leader`
  instead, mirroring `Scene::SkillMenu`, which always has a caster selected
  before it reaches its own no-prompt scopes. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code (recording the `nil` actor `#use_special_item` was called
  with) before the fix.
