- **The F9 debug menu's Map viewer gained a Select mode and a debug teleport.**
  Press **R** inside the whole-map viewer to drop a single-tile cursor on the
  player's own position; arrow keys move it one tile at a time (the viewport
  auto-scrolling to keep it in view), and the header reports the tile
  underneath — coordinates, whether the chipset marks it passable or blocked,
  and the name of any map event standing there. **C** warps the player onto
  the selected tile and returns to the map; **B** backs out of Select mode
  without moving anyone, or closes the viewer entirely from pan mode. The warp
  goes through `Game::State#pending_teleport`, the same queued-warp mechanism
  a Teleport field skill uses, so `Scene::Map` runs the real teleport
  machinery (map reload, access/BGM setup) on its next update rather than the
  viewer editing the player's position by hand.
