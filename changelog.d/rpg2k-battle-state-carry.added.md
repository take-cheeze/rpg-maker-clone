- RPG Maker 2000: **status conditions now carry through a battle**, and a battle
  medicine cures them. A `Game::Battle::Combatant` seeds its status set from its
  source actor (`from_actor`), so a member who walked into the fight afflicted
  (e.g. a map Change Condition) is still afflicted in battle; enemies carry none.
  `battle_item_command` now reports the medicine's cured `state_set` alongside its
  HP/SP recovery, and `apply_command` **removes those states from the target**
  (an antidote / herb used mid-fight — unconditional, matching the field item
  cure). `Battle#apply_to_party` writes each ally's surviving status set back to
  its actor (before the HP write-back, so `set_hp` still has the last word on the
  death state), so the cure — or an unremoved ailment — persists out of the
  fight. Covered by new `scripts/rpg2k_logic_check.rb` checks (a battle antidote
  cures only its listed state and the cure carries out; an uncured status
  survives the battle). Afflicted-battler behaviour (poison ticking, sleep
  skipping a turn) and in-battle *infliction* (attack skills rolling
  `state_chance`) — which need the State database — remain follow-ups.
