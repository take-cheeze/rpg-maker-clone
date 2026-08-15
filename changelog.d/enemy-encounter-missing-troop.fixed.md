- **Enemy Encounter and random encounters no longer open a battle against a
  dangling enemy-group (troop) id** — a database shrink can leave one behind,
  shown as "?" in the editor. `Game::Interpreter#do_enemy_encounter` /
  `#start_random_battle` (`mruby-rpg2k/mrblib/interpreter.rb`) now check the
  troop id first and log a `[RPG2k] Enemy Encounter: ...` diagnostic instead
  of opening a real battle screen (SE, BGM swap, status panel) against zero
  enemies: a scripted encounter resolves as an immediate Escape would (its
  [Escape] handler, or ending the event under "abort on escape", or simply
  continuing), and a random encounter just never arms the wait. Covered by
  five new `scripts/rpg2k_logic_check.rb` checks.
