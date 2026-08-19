- **RPG2000/2003 events:** The Change Equipment event command's "Remove
  Equipment" mode now removes the slot the designer actually picked,
  matching RPG_RT. It previously read the slot from the wrong command
  parameter (the one that only means anything in the sibling "Equip"
  mode), so it usually unequipped the weapon slot regardless of which
  slot was chosen. Covered by strengthened and new
  `scripts/rpg2k_logic_check.rb` checks.
