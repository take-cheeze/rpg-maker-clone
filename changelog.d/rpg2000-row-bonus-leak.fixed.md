- **Every RPG2000 ally basic attack was silently dealing RPG2003's front-row
  +25% damage bonus.** `Game::Battle#row_adjusted?` checked `row == ROW_FRONT`
  for an attacker without first checking whether the fight is even an RPG2003
  one; the front row is every RPG2000 ally's permanent, unchangeable default
  (there is no Row command to ever leave it in 2000), so the check was
  trivially true on every swing, in every RPG2000 game, for the whole life of
  the row feature. The back-row *defender* term really was a no-op outside
  2003 (row can never read `ROW_BACK` there), which is why nothing caught the
  asymmetry between the two branches. `row_adjusted?` now returns `false`
  outright unless the battle is RPG2003. See ADR 0053's follow-up note.