- **A skill whose Attack/Defense Attribute is weapon-type now needs a matching
  weapon equipped to cast.** yado.tk: armour carrying the same attribute does
  not satisfy the requirement, only a weapon does; skill usability modelled no
  attribute-based equip-gating at all before this. `Game::Party
  #weapon_attribute_ready?` checks each of a skill's `attribute_effects` ids
  against the database `property` table's weapon/magic `type` field, and for
  the weapon-type ones requires `Actor#weapon_attributes` (the equipped
  weapon's own `attribute_set`, already used for battle damage scaling) to
  cover all of them — a magic-type attribute gates nothing. Wired into
  `#can_cast?`, the single choke point every cast path (field, battle,
  escape/teleport/switch skills) already runs through. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the pre-fix
  code before the fix.
