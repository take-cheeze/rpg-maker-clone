- **Teleport (10810 / Recall to Location)** now resumes the interpreter
  instead of stopping it once the destination map is up. RPG_RT keeps
  running the rest of an event's command list after a teleport lands, which
  is what the standard "Erase Screen, Teleport, Show Screen" transition
  relies on -- the trailing Show Screen is meant to lift the erase overlay
  once the new map is drawn. `Scene::Map#perform_teleport` used to abandon
  the rest of the command list on every teleport, so that Show Screen never
  ran and the erase overlay stayed up for the rest of the game. Nepheshel's
  opening hits this on its very first scene transition, so the game was
  unplayable past it -- the map kept loading and running underneath, but the
  screen (and the message window, drawn under the same overlay) never
  reappeared.
