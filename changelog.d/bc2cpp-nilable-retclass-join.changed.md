- bc2cpp's self-call return-class proof (`compute_class_return_names`) now
  collects every definition reaching a `RETURN`, not only a single dominating
  one. It accepts `rescue` handlers and `nil` returns (the "class or nil"
  contract ivar class hints already have), and admits a method name with
  several definitions when all of them return the same class. 25 more ivars
  get a class hint (273 -> 298; OPAQUE 502 -> 477), among them
  `RPG2k::Scene::Map`'s `@chipset`, `@chipset_bmp`, `@windowskin` and
  `@tiles_chipset*` and every menu's `@skin` and scroll arrows. See ADR 0199
  and `scripts/bc2cpp_nilable_retclass_check.rb`.
