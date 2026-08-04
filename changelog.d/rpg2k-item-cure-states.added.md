- RPG Maker 2000 item menu: a medicine now **cures status conditions**. When an
  item has `reverse_state_effect` set, using it removes the states listed in its
  `state_set` (a byte per state, index i → state id i+1) from the target — the
  antidote / herb case — unconditionally, matching EasyRPG's item algorithm.
  `Game::Party#use_medicine` cures alongside the HP/SP recovery and consumes the
  item when *either* healed or cured; `item_effective?` reports such an item as
  usable when the target is afflicted even at full HP, so it is no longer greyed
  out. `Game::Party#item_cured_states` exposes the cured set (empty for a
  non-reverse item, whose states would be *inflicted* — left to battle). Covered
  by new `scripts/rpg2k_logic_check.rb` checks (curing only the listed states, the
  no-op-when-unafflicted case, a combined heal+cure item, and the non-reverse
  case). Builds on the actor-state model added just before; inflicting states
  (`state_chance`) remains a follow-up.
