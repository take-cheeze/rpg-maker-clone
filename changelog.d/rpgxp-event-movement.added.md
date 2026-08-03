- RPG Maker **XP** autonomous event movement — map events now roam. New
  `RPGXP::Game::Character` (a movable grid entity), `RPGXP::Game::MoveType`
  (the page's autonomous type: fixed / random / approach) and
  `RPGXP::Game::MoveRoute` (a cursor over an `RPG::MoveRoute` that executes the
  XP move-command set — the cardinal and diagonal moves, move toward/away/forward/
  backward/random, the turns, jump/wait, and the switch / speed / frequency /
  walk-anime / step-anime / direction-fix / through / always-on-top / graphic /
  opacity / blend / play-SE side effects) drive the events. `Scene::Map` gives
  each event a persistent character (kept across page re-selection so a roamed
  event doesn't snap back to its spawn tile), steps it per its page's move type
  or custom route paced by move frequency, and keeps events off each other, the
  player and impassable tiles via a `MapWorld` adapter. The **event-touch**
  trigger (an event walking into the player) now fires too. Covered by new
  `mruby-rpgxp/test` cases (character moves/turns/facing, move-route
  movement/blocking/side-effects, move-type direction selection).
