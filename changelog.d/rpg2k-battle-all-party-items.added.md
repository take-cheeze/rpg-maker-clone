- RPG Maker 2000: battle **items can now target the whole party** (item scope 1).
  `Game::Battle#command_item_all` queues a volley of per-member recoveries reusing
  the all-target machinery, so an all-party potion / antidote heals HP / SP and
  cures status from every living ally in one action — and a single item is
  consumed for the volley (only the first hit carries `item_id`, so the scene's
  per-entry bag deduction fires once). `Game::Party#item_all_allies?` flags a
  scope-1 medicine, and the battle item menu casts it on the whole party without a
  target prompt. Covered by new `scripts/rpg2k_logic_check.rb` checks (every ally
  is healed for one consumed item, a party antidote cures each afflicted member
  while leaving other statuses, and the scope flag is read).
