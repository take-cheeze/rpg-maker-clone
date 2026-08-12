- RPG Maker 2000: an event's custom move route now continues from where it
  left off when a page switch selects a page carrying the byte-identical
  route, instead of always restarting from the top. `Game::MoveRoute
  .same_route?` compares the old and new page's route commands, repeat and
  skippable flags, and `Scene::Map` carries the in-progress route object
  across the page rebuild only when they match — matching RPG_RT, which
  restarts on any other page switch (a different route, or no custom route).
  Covered by new `scripts/rpg2k_scene_check.rb` checks.
