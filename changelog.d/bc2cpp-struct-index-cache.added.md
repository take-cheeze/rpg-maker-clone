- `event[:page]`/`this_event[:id]`-style bracket access on a `Struct.new(...)`
  instance (`RPG2k::Scene::Map::MapEventState`/`MessageState`/`ShopState`/
  `ShopQuantity`, `Game::Battle::Combatant`, ...) no longer pays a full
  `mrb_funcall` into `Struct#[]`'s own native linear member-name scan
  (`mrb_struct_aref`, `3rd/mruby/mrbgems/mruby-struct/src/struct.c`) on every
  call. A new whole-program scan (`STRUCT_MEMBERS_ANALYSIS`,
  `tools/bc2cpp/bc2cpp.rb`'s `detect_struct_new_members`) records each
  `Struct.new(:a, :b, ...)` owner's own member list, with or without a
  trailing `do ... end` block; a `[]` call site whose argument is a
  compile-time literal Symbol matching a known member reads the underlying
  array directly (`RARRAY_PTR`/`RARRAY_LEN` -- valid on a Struct instance
  directly, since `MRB_TT_STRUCT`'s own real C layout is `struct RArray`)
  behind an exact-class guard, bounds-checked the same defensive way
  `struct_aref_sym` itself is. A non-literal key, or a literal that names no
  known struct's member, keeps the ordinary dispatch. Measured on the RPG2k
  map scene: native `mrb_struct_aref` calls over a fixed run fell from 28,882
  to 2,936 (the remainder is dynamic-key sends and the still-interpreted
  `Struct#each`/`#each_pair`/`#select`/`#dig`, mruby's own mrblib, which this
  change does not touch). New `scripts/bc2cpp_struct_index_check.rb`.
