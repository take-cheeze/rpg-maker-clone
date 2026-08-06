- **A weapon's 会心必殺 rate now reaches the fight.** `critical_hit` (item field
  18) is the largest unread field in the equipment audit — 75 of Nepheshel's
  items carry one — and it could not simply be read, because RPG_RT *adds* the
  weapon's percentage to the wielder's own 1-in-N rate and no denominator
  expresses "1/30 and 20% more". Criticals are therefore modelled as a
  probability: `Game::Actor#crit_chance` (and the enemy's) returns basis points
  over `Game::CRIT_SCALE`, and `Battle#critical?` rolls against it.
- **Only a weapon grants the bonus.** The six of Nepheshel's 75 items that are
  not weapons carry exactly 100 apiece alongside a `hit` of 70 — another
  weapon-only field — which is the editor leaving weapon fields untouched in the
  record every item type shares, not six pieces of armour that always critical.
