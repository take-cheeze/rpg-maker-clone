- **The F9 debug menu gained an Animation page: a battle-animation preview.**
  Up/Down steps a database animation id by one and L/R by ten; C plays it
  back on the field map, screen-centred, through `Scene::Map`'s own
  animation player — the same one a real battle round uses
  (`Scene::Battle#start_battle_animation` calls the identical
  `build_animation`/`anim_target`/`map_animation=` trio) — and closes the
  debug menu so the animation is what's on screen next.
