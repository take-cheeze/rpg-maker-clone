- **The action button now also answers a same-layer Player Touch / Event
  Touch event on the faced tile**, not only a Trigger-0 (Action) one.
  `Scene::Map#try_action_trigger` only ever started a plain Trigger-0 event
  from the tile the party faces; matching EasyRPG's own
  `Game_Player::CheckActionEvent` (`src/game_player.cpp`), whose first check —
  `CheckEventTriggerThere({Trigger_touched, Trigger_collision}, ...,
  triggered_by_decision_key: true)` — runs against the faced tile *before* it
  ever looks at a same-tile Trigger_action event there, pressing the action
  button while facing a same-layer touch-triggered event now starts it too,
  with "the decision key started this event" (Conditional Branch type 8) true
  instead of false. This is the "face a disguised wall and press confirm to
  search" idiom real RPG2000 content leans on: an event authored with a
  Player Touch trigger so walking into it also works, whose own commands gate
  the actual reveal (a sound effect, a self-targeted Move Event that opens it
  and switches Through Mode on) behind that exact condition. Previously the
  action-button path never started such an event at all, so any content built
  this way — Nepheshel's own copy-pasted "HiddenDoor" event, on well over a
  hundred of its maps — never played its reveal animation and never became
  passable, no matter how the player approached it. Covered by a new check in
  `scripts/rpg2k_scene_check.rb`.
