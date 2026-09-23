- bc2cpp now calls a module's own singleton method directly when another
  singleton method of that module calls it with an implicit `self`
  (`Game.camera_offset` calling `clamp`). A runtime-class-checked call chain
  now also accepts a subclass that inherits the method unchanged (`db`/`term`
  on a `Scene::Base` subclass). Both keep their existing soundness gates, and
  the chain keeps its `mrb_funcall` fallback. On the RPG2000 map scene trace
  this removes about 3.3 dynamic calls per frame, and POLY sites go from
  3,232 to 3,196. Covered by `scripts/bc2cpp_inherited_self_devirt_check.rb`;
  see docs/adr/0207.
