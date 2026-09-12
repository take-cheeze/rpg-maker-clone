- Swept `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_ARG_TARGETS` against
  `mruby-rpg2k/mrblib/scene/battle.rb`'s own dense annotation cluster,
  deliberately left out of scope by round 41 ("its own dedicated round,
  not a follow-up item") and again by round 46. 9 new entries were added
  to `RPG2k::Scene::Battle`: `#battler_z` (`i`), `#actor_sprite_z` (`i`),
  `#battle_grid_position` (`party_size`), `#move_battle_target_cursor`
  (`foes_count`), `#move_battle_list_index` (`index`/`delta`/`size`),
  `#battle_skill_unavailable?` (`cost`), `#draw_gauge_system2`
  (`cur`/`max`), `#draw_number_system2` (`value`), and
  `#refresh_battle_list_arrows` (`scroll`/`row_count`/`rows`). Every one
  was checked against the mechanism's usual two-part bar (no `nil`-guard
  on the annotated position -- each is a direct, unguarded arithmetic/
  comparison the interpreted path already crashes on for a bad value
  today, or a caller-guarded/provably-Integer real call site, individually
  traced) AND confirmed to actually produce a real, error-free compiled
  `_impl` via a from-scratch, un-`SKIP_UNSUPPORTED`-hidden regenerated
  `rpg2k_compiled_gen.cpp` (a real host `mrbc` built fresh in this round's
  own worktree, following the same recipe round 46's own writeup already
  documents). Also swept `mruby-rpg2k/mrblib/game/battle_support.rb`'s own
  3 annotations and `mruby-rpg2k/mrblib/scene/battle_support.rb`'s own 1 --
  both already fully accounted for by prior rounds (`Game::EnemyAi#enemy`/
  `#set_switch` already excluded by round 46 for a `nil`-tolerant guard;
  `Scene::Base#sticky_list_top` already on this list since round 46), so
  neither needed new work.

  Reading each candidate's own real generated function BODY, not just
  grepping for its `_impl(mrb_state* M, ...)` declaration line, caught two
  genuine near-misses this round's own first pass would otherwise have
  taken on faith -- the exact lesson round 46 flagged going in: that
  declaration line is emitted unconditionally, even when the body under it
  is nothing but `#error unhandled opcode ...`. `#enter_battle_result`
  (`result`) and `#battle_result_lines` (`result`) both looked sound on
  paper but each hits a real, unsupported `BLOCK`/`SENDB` opcode pair in
  its own body (`[@ui[:status_win], @ui[:cmd_win]].each { |w| ... }`;
  `troop.drops(...).each do |iid| ... end`, `@state.party.actors.each do
  |a| ... end`) -- no real `_impl` exists for either, independent of a
  second, unrelated soundness gap also found for the same pair:
  `#enter_battle_result`'s own `result` traces to `Game::Battle#result` at
  one real call site (`#leave_battle_event_phase`) that cannot be proven
  non-`nil` without a much deeper battle-event trace, the exact
  `Game::Interpreter#resume_battle` gap round 46 already found and
  declined to force through; `#battle_result_lines`'s own `result` is
  nil-*tolerant* by construction (`return ... if result == :escape; return
  ... unless result == :victory`, both bare `==`), the same
  `knows_skill?`/`learn_skill` shape already excluded. `#battle_level_up_
  lines` (`before_level`, caller-guarded and otherwise sound) and
  `#draw_battle_stat_segment` (`x`/`w`, the identical "crashes already"
  shape round 46's own `Scene::Base#draw_stat_segment` entry already
  established) each looked clean on the annotated position alone but also
  hit their own real `BLOCK`/`SENDB` pair (`(before_level+1..actor.level)
  .each do |lv| ... actor.learn_table.each do |sid, at| ... end end`;
  `pieces.each do |text, pw, align, color| ... end`) -- moot regardless.
  `#battle_list_window` (`w`) was never a real prospect at all: four
  trailing keyword arguments with defaults make it non-mandatory arity,
  confirmed directly against its own real `#error ... has non-mandatory
  arguments` line.

  Every generated `_impl` signature and its entry wrapper's
  `mrb_get_args` format string were confirmed to switch from boxed
  `mrb_value` to native `mrb_int` at exactly the annotated positions, with
  a new `mrb_as_int(M, ...)` unboxing wrapper added at each MONO
  devirtualized call site and nothing else changed; a full
  `wio_registered_methods.rb` TSV dump (owner/name/arity/visibility/
  singleton) for all three `*-compiled` gems is byte-for-byte identical
  before and after (this mechanism only ever changes a calling
  convention, never a registration); `mruby-lcf-compiled`'s and
  `mruby-rgss-compiled`'s own regenerated output is byte-for-byte
  identical before and after too (no cross-gem devirtualization touches
  `RPG2k::Scene::Battle`); and all three `*-compiled` gems' own
  `register.cxx` were compiled for real (`g++ -std=gnu++17 -c`, against
  the real regenerated `_gen.cpp`/cross-gem `_decls.h` headers) with zero
  errors.
