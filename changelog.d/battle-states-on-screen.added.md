- Status conditions are now **shown** on the RPG2000 battle screen, not only
  simulated. A new `Game::States` reads the display side of the database
  `situation` table, and the screen uses it in three places: the status panel
  gained a condition column carrying the *significant* state — death first, then
  the highest `priority`, ties to the later id (EasyRPG's
  `State::GetSignificantState`) — drawn in the state's own palette colour, or the
  database's `normal_status` term when the battler is clear; the action banner
  announces each condition an action lands or lifts with the state row's own
  sentences (`message_actor` / `message_enemy` / `message_recovery`, worded from
  the speaker's side), which now covers being downed too, in place of the
  invented `— defeated!`; and a battle page's **Change Monster Condition** (13130)
  rebuilds the panel, which it could not before because the command writes
  straight to the live combatant rather than queueing a request.
