- A troop battle-event page whose condition box is entirely unticked no longer
  fires every turn. RPG_RT reads "no trigger" as **never**, not as "always"
  (a reference implementation's own conditions-met check opens with exactly
  that test, though this is not independently confirmed against genuine
  RPG_RT under wine), which is the
  opposite of how every other RPG2000 page kind treats vacuously-satisfied
  conditions — `Game::BattlePage.active?` had taken the natural reading. Both
  test beds do carry such pages (446 of Nepheshel's 3265, all 88 of
  mtf-meido-action's) and every one of them is empty, so no real game changes
  behaviour; the rule is fixed before a game that puts commands on one is met.
