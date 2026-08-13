- **Battle damage is hard-capped at 999.** `Game::Battle` had no ceiling on
  a single hit's damage anywhere: a normal attack (including a ×3 critical
  or a ×2 charged blow), an attack skill/item, an enemy self-destruct, and
  per-turn state slip damage could all subtract an uncapped amount from a
  target's HP, something RPG_RT's fixed three-digit damage popup could
  never even display. Added `Game::Battle::DAMAGE_CAP = 999` and clamped
  the final per-hit value at every one of those sites right before it
  lands.

- **An in-battle heal cannot revive a downed (0 HP) combatant** — verified
  already correct, not a bug. `Game::Battle#apply_command` /
  `#apply_command_all` were already gating every Skill/Item command on the
  target's `dead?` state before it ever reaches the HP-raising code, the
  in-battle mirror of `Game::Actor#change_hp`'s field-side `return @hp if
  dead?` guard. No behaviour change here; comments were added documenting
  the parity, and regression coverage was added alongside the damage-cap
  fix above.
