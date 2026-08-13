- **A Timer with "valid during battle" checked now force-ends the fight the
  instant it reaches 0:00**, regardless of encounter source, matching
  yado.tk. `Scene::Map#update` previously discarded `Game::State#tick_timer`'s
  return value; it now calls `#finish_battle(:abort)` — the same outcome
  Terminate Battle produces, reachable from any battle phase — the moment a
  battle-flagged timer expires mid-fight.
