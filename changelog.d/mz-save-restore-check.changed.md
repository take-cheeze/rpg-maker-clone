- **MZ's save check now proves the state comes back.** `[MZ-SAVE] saved=true
  exists=true loaded=true` said only that the promise chain settled — the slot
  deflated, `savefileExists` found it and `loadGame` resolved — which is equally
  true of a load that restores nothing, or one that quietly starts a new game.
  The probe now moves six fields off their defaults before saving (gold, a
  switch, a variable, an actor's HP, the inventory, the player's position),
  overwrites every one of them between the save and the load, and compares what
  comes back: `restored=true`, or both signatures printed so the failure names
  the fields that did not survive. Arming the fields first is what makes it
  bite — a fresh game and an unwritten save both read as the defaults. The
  round-trip does work; with `loadGame` stubbed out, the three old claims still
  pass while the new one fails.
