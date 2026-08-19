- **The F9 debug menu gained a Map page.** Left/Right on the Switch/Variable
  pages now cycles through a third page, Map, which shows the current map id,
  size and the player's tile coordinates; C on it opens a new whole-map debug
  viewer (`Scene::MapViewer`) that draws every tile of the current map at one
  pixel per tile — green where the chipset says a character can stand, dark
  red where it can't — plus a marker for the player and one for every active
  map event, so a map bigger than one 320x240 screen can be read at a glance.
  Arrow keys pan when the map doesn't fit on screen at once, C recentres on
  the player, and B closes back to the debug menu. Like the rest of the F9
  menu it is Test Play only and read-only against `Game::State` — it never
  writes anything back, so it stays a runtime debugging aid rather than an
  authoring tool and cannot collide with a real RPG Maker project.
