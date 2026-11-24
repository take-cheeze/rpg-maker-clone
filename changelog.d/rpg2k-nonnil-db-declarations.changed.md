- The bc2cpp declarations of the database (`@db`, `RPG2k#db`,
  `Scene::Base#db`), a scene's parent, the party (`Game::State#party`,
  `Game::Shop`'s `@party`) and a map's unit no longer allow nil. None of
  them is ever nil, so the compiled engine drops their nil tests, which saves
  about 3 KB of Wio flash.
