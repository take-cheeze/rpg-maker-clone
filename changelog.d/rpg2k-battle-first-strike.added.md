- RPG Maker 2000: a **pre-emptive first strike** now gives the party a free
  opening round. The Enemy Encounter command's first-strike flag was already
  decoded but ignored; `Game::Battle` now takes a `first_strike` option, and
  `refill_queue` drops the enemies from round 1's turn order so only the party
  acts while the ambushed foes skip their turn — they rejoin normally from the
  second round. Wired into the live battle from the encounter request. Covered by
  new `scripts/rpg2k_logic_check.rb` checks (the party acts first while enemies
  skip round 1, enemies rejoin in round 2, and a normal encounter still has both
  sides act in the opening round).
