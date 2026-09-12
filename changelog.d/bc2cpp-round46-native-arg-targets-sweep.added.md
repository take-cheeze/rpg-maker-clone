- Re-checked `NATIVE_ARG_TARGETS` against every remaining real
  `# bc2cpp: (fixnum...)`/`(symbol...)` annotation this file's own
  whole-program `Annotations.extract` result can see, restricted to the
  non-`scene/battle.rb` remainder round 41's own follow-up explicitly left
  open (`scene/battle.rb`'s own dense ~25-annotation cluster stays
  deliberately out of scope again this round). 6 new entries were added,
  each individually traced through the real regenerated
  `rpg2k_compiled_gen.cpp` against the mechanism's usual two-part bar (no
  `nil`-guard on the annotated position, every real caller's own argument
  provably Integer/Symbol) AND, this round, additionally confirmed to
  actually produce a real compiled `_impl` at all via a real,
  un-`SKIP_UNSUPPORTED`-hidden regen: `RPG2k::Scene::Base#draw_stat_segment`
  (`x`/`w`), `RPG2k::Scene::Base#sticky_list_top` (`sel_row`/`row_count`/
  `visible_rows`, defined in `scene/battle_support.rb`'s own reopen of
  `Base` — the "own 1" annotation round 41 also named there),
  `RPG2k::Scene::SaveLoad#build_arrow_sprite` (`src_y`),
  `RPG2k::Scene::Menu#wait_term_for` (`key`),
  `RPG2k::Scene::Menu#enter_actor_selection` (`key`), and
  `RPG2k::Scene::VehicleWorld#initialize` (`type`). Every generated
  `_impl` signature and its entry wrapper's `mrb_get_args` format string
  were confirmed to switch from boxed `mrb_value` to native `mrb_int`/
  `mrb_sym` at exactly the annotated positions; a full
  `wio_registered_methods.rb` TSV dump (owner/name/arity/visibility/
  singleton) for all three `*-compiled` gems is byte-for-byte identical
  before and after; and `mruby-rpg2k-compiled/src/register.cxx` was
  compiled for real both directly (`g++ -std=gnu++17 -c`) and through the
  project's own real incremental build (`RPGMAKER_BC2CPP=1 rake`, linking
  clean into `libmruby.a`) — zero errors either way.

  Two real, seriously-considered candidates were found unsound and
  deliberately excluded: `Game::EnemyAi#enemy`/`#set_switch` (both open
  with an `id && id > 0`-style guard, the same `knows_skill?`/
  `learn_skill` shape already excluded), and `Game::Interpreter#
  resume_battle` (its own `result` traces back to `Game::Battle#result`,
  which this round proved can still be `nil` on one real path —
  `Scene::Battle#leave_battle_event_phase` reading it without an
  intervening `#end_round` call for that round — that could not be fully
  ruled out without a much deeper trace into the battle-event state
  machine, the same "can't fully verify" call `Interpreter#apply`/
  `Game::State#initialize` already model).

  Four more looked sound on the annotated position alone but turned out to
  have no real compiled `_impl` to retype at all, caught only by an actual
  compile rather than reasoning about the Ruby source — a real lesson of
  this round, since a `#error unhandled opcode BLOCK/SENDB/SUPER` line
  carries no owner/method name of its own the way the "has non-mandatory
  arguments" error does, so a name-anchored grep for the candidate walks
  right past it: `RPG2k::Scene::Base#build_list_arrow_sprite`/
  `#draw_system_text` (both carry a trailing optional argument, landing in
  the existing "does not compile clean" exclusion category), and
  `RPG2k::Scene::SaveLoad#draw_slot_faces`/`#initialize` (a real
  `each_with_index do |...|` block, and `super`/`.map { ... }`
  respectively, neither in this prototype's supported opcode subset).
