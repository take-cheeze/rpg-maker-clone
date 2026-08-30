- **Shop screen:** The status and gold side panels now follow a reference
  implementation's own visibility rule, not independently confirmed against
  genuine RPG_RT under wine: visible on the buy list, the
  quantity counter and the purchase/sale confirmation; hidden on the
  command menu and the sell list. Previously they went dark for the
  quantity counter and confirmation (the opposite of RPG_RT) and the gold
  panel never hid at all. Covered by two new `scripts/rpg2k_scene_check.rb`
  checks.
