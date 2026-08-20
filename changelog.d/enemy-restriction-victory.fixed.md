- **Battle:** a fully-restricted enemy troop (e.g. every enemy locked into a
  Stone-style "do nothing" status with 0% self-cure) no longer ends the
  fight in an instant, damage-free victory -- matching RPG_RT's own
  `Game_Battle::CheckWin`, which only checks whether every enemy is
  dead or hidden, unlike the party's own defeat check, which does widen to
  "permanently unable to act." A live-but-restricted enemy troop now has to
  actually be reduced to 0 HP (or hidden/removed) like real RPG_RT, instead
  of ending the fight for free.
