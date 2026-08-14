- **A living ally under a "do nothing" restriction (asleep/paralysed) or a
  forced attack-ally/attack-enemy restriction (confused/berserk) no longer
  gets a manual Attack/Skill/Defend/Item command prompt**, matching real
  RPG_RT's `Scene_Battle_Rpg2k::SelectNextActor`, which skips straight past
  such an ally with no prompt at all — auto-assigning "do nothing" or a
  random forced target instead. `Scene::Map`'s battle command loop only ever
  filtered `#living_allies` by `dead?`, so an afflicted-but-alive ally still
  opened the ordinary menu and waited on a choice that
  `Game::Battle#apply_turn_states`/`#strike` already discard or override
  regardless of what gets picked — including the degenerate case where every
  living ally is restricted at once, which previously froze the command
  phase forever with no player input able to move it along. Fixed with a new
  `Game::Battle#command_restricted?` predicate and a
  `Scene::Map#skip_restricted_actors`/`#open_next_command` pair (plus a
  matching backward skip on Cancel) that advances past every restricted ally
  automatically, routed through battle open, the per-actor advance, and both
  battle-event-page resume points that hand control back to the command
  phase.
