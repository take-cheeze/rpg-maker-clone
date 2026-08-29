- **An action pattern's "Enemies" condition now ranges over the acting
  monster's own living troop-mates, instead of the player party's headcount.**
  Ported from a reference implementation, not independently confirmed against
  genuine RPG_RT under wine: the real condition reads the monster troop's own
  active-battler count, not the
  player party's. Any action pattern using this condition (a boss escalating
  once its escorts are down, a minion firing only while several troop-mates
  remain) evaluated against the wrong side's population entirely.
