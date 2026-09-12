- The same round-41 sweep re-checked `NATIVE_ARG_TARGETS` against every
  real `# bc2cpp: (fixnum...)`/`(symbol...)` annotation in
  `mruby-rpg2k/mrblib/scene/*.rb` and `game/battle_support.rb` — files a
  prior round's own "later round re-checked every remaining annotation"
  pass never actually covered (it only ever named `game.rb`/
  `interpreter.rb`/`lcf.rb`). 7 new entries were added, each individually
  traced through the real regenerated `rpg2k_compiled_gen.cpp` against the
  same two-part bar the mechanism has always required (no `nil`-guard on
  the annotated position, every real caller's own argument provably an
  Integer) and confirmed byte-for-byte against a before/after regen:
  `RPG2k::Scene::SaveLoad#move_selection`, `RPG2k::Scene::Title#
  move_selection`, `RPG2k::Scene::ItemMenu#move_item_cursor`,
  `RPG2k::Scene::ItemMenu#move_teleport_cursor`, `RPG2k::Scene::Order#
  move_cursor`, `RPG2k::Scene::Map::LRUBitmapCache#initialize`, and
  `RPG2k::Scene::SaveLoad#draw_slot_label`. Every real caller of the five
  cursor-movement methods passes a literal Integer; `LRUBitmapCache`'s own
  constructor argument traces through its one caller's own
  `#constrained_scale` helper, which always returns a real Integer.

  A handful of similarly-shaped candidates were investigated and
  deliberately left off: `RPG2k::Scene::Base#value_font_color` (a real
  `max &&` guard on its own second annotated position, the same
  `knows_skill?`/`learn_skill` exclusion shape the original round already
  established), `RPG2k::Scene::ItemMenu#prompt_item_target` (its own `id`
  traces back through `#choose_item`'s internal locals rather than a bare
  parameter — the same "much deeper trace" the original round already
  declines to force through), and `RPG2k::Scene::Base#clip_text_to_width`
  (sound, but has zero real devirtualized call sites today — its one real
  caller crosses an inheritance boundary this compiler's MONO/TYPED
  devirtualization deliberately never resolves — judged not worth the
  added surface for zero measured benefit). `scene/battle.rb`'s own ~25
  annotations and `scene/battle_support.rb`'s own 1 remain unaudited,
  left for a future round.

  Separately, the same sweep confirmed `DIRECT_CONSTRUCT_TARGETS` has no
  addable candidate today: `Game::Switches`/`Game::Timer`/`Game::
  MessageConfig` (alongside the already-documented `Game::Screen`) all
  clear the mechanism's real 4-part soundness bar but hit the same
  already-known "bare-reference" limitation in `trace_new_target`'s own
  `GETCONST` case (it never resolves a lexically-scoped bare constant
  reference to its real fully-qualified path) — verified empirically by
  temporarily adding all four and confirming the regenerated output is
  byte-for-byte unchanged. Left undocumented as anything other than a
  widened instance of the same pre-existing, deliberately-deferred
  `trace_new_target` limitation.
