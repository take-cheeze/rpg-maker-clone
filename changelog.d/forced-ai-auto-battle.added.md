- **強制AI (Forced AI) actors now fight on their own, matching RPG_RT.** An
  actor (or RPG2003 class) flagged this way never showed the ordinary
  Attack/Skill/Defend/Item command menu in real RPG_RT — the engine picks
  its action automatically every round — but this codebase always opened
  the manual prompt for one regardless, since the database field was parsed
  and never read anywhere. Ported a reference implementation's default
  auto-battle algorithm, not independently confirmed against genuine RPG_RT
  under wine, as `Game::Battle
  #choose_auto_battle_command`: a Forced-AI actor's own known skills and a
  plain Attack are each ranked (heal/revive value for an ally-scope skill,
  damage-vs-HP for an enemy-scope one or a basic swing, each with the same
  SP-cost penalty and "first living enemy" bonus real RPG_RT's own formula
  carries), and whichever ranks higher is queued automatically — no manual
  command window shown at all. `Scene::Map`'s command-selection loop now
  skips (and auto-commands) such an actor the same way it already does for
  one under a "do nothing"/forced-attack state restriction.
