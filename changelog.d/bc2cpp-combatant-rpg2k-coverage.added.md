- `mruby-rpg2k-compiled` gains two more real, never-before-owned compile
  targets, both real instance-method classes (no `.singleton` mechanism
  needed for either): `Game::Battle::Combatant` and `RPG2k` itself.

  `Game::Battle::Combatant` (`mruby-rpg2k/mrblib/game/battle.rb`) is the
  `Struct.new(...) do ... end`-defined ephemeral per-fight battler
  snapshot `Game::Battle` operates on -- all 16 of its own real `def`s
  compile clean (`#atk_states`, `#row`, `#gauge`, `#dead?`,
  `#display_max_hp`, `#display_max_mp`, `#strike_count`, `#half_sp_cost?`,
  `#turns_taken`, `#next_battle_turn`, `#out_of_play?`, `#member?`, `#int`,
  `#state?`, `#back_row?`, `#gauge_full?`), no new opcode work needed. No
  ivar embedding: a `Struct`'s own members are never backed by `iv_tbl` in
  the first place, so none of these methods ever touches an ivar.

  `RPG2k` (`mruby-rpg2k/mrblib/main.rb`) is the top-level app/game object
  `main.cxx` constructs and drives -- 15 of its own real methods compile
  clean, including `#initialize` itself (`#initialize`, `#hide_title?`,
  `#current_scene_name`, `#show_title?`, `#boot_title_or_new_game`,
  `#push_title_screen`, `#push`, `#pop`, `#pop_to_map`, `#map_scene`,
  `#map_path`, `#db_path`, `#load_map`, `#bug_report_interp_text`,
  `#bug_report_stamp`). `#initialize` DOES compile clean with pure
  mandatory arity, but the class still gets zero real embedded ivars:
  every one of its own ivars is a type (`LCF::Database`, `String`,
  `Array`, boolean) `IvarLayout`'s own embedding lattice never models, so
  the per-method `every_accessor_compiles?` gate is never even reached.

  Both classes' own real devirtualization proofs confirmed directly in
  the regenerated output: `Game::Battle`'s own already-compiled methods
  now call several `Combatant` methods directly (no `mrb_funcall`), and
  already-shipped `RPG2k::Scene::ItemMenu#apply_switch_item`'s own
  `@parent.pop_to_map` now devirtualizes straight into `RPG2k#pop_to_map`
  too. Verified with a full before/after diff: every already-shipped
  owner's own generated code, ivar embedding, and registration-call count
  are unchanged -- confirmed by `nm` on a real, freshly built
  `libmruby.a`, not just by inspection.
