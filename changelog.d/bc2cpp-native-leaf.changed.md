- **bc2cpp:** a class that mruby-rgss defines in C++ and the engine reopens in
  Ruby (`RGSS::Bitmap`, `Font`, `Window`, `Sprite`, ...) now counts as a
  proven leaf, and a superclass written as a path (`< RPG2k::Scene::Battle`)
  no longer makes every `Battle` a parent. The closed RPG2000 build drops 48
  engine by-name owner calls (`blt`, `fill_rect`, `draw_text`, `stretch_blt`
  and the `Game::Battle` calls).
