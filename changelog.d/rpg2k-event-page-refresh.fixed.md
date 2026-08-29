- **Event pages re-select when their conditions change.** A page's conditions
  read the switches, the variables, the party roster and its items, but the
  pages were only ever chosen when the map loaded — so an event kept whichever
  page it started the visit with until the player left the map and came back.
  That breaks the idiom every RPG2000 game is built on: talk to someone, set a
  switch, and they turn into their page 2. `Scene::Map#refresh_event_pages`
  re-selects every event's page whenever anything a condition reads has changed,
  carrying each event's **position and facing** across (RPG_RT changes an
  event's page, not where it stands) and rebuilding the parallel processes,
  since a page change can add or remove one. Erased events stay erased. Rather
  than flagging each command the way a reference implementation's own
  refresh-flagging does (not independently confirmed against genuine RPG_RT
  under wine) — which misses any path that is not an event command, such as using an item from
  the menu — `Game::Switches`, `Game::Variables` and `Game::Party` each carry a
  revision counter the scene watches, so every writer is covered by
  construction. Writing a value that is already there does not count, so a
  parallel process setting the same switch every frame costs nothing, and the
  per-frame sweep rebuilds only when a page has actually flipped.
