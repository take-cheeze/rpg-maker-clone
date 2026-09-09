- **Fixed `NameError: uninitialized constant Game::Battle`** in four
  `scripts/*.rb` CRuby check scripts (`export_nano7_map.rb`,
  `export_nano7_map_check.rb`, `rpg2k_command_soak.rb`,
  `rpg2k_testbed_logic_check.rb`) — each `load`s `mruby-rpg2k/mrblib/game.rb`
  directly but never `game/battle.rb`, which `Game::Battle` moved into when
  it was split out of `game.rb` (docs/adr/0107). Caught by CI's own
  `ruby-checks` job on take-cheeze/rpg-maker-clone#1605, which is the first
  time these two scripts (`rpg2k_command_soak.rb`/
  `rpg2k_testbed_logic_check.rb`) actually exercised a `Game::Battle`-
  touching code path since that split landed. Fixed the same way
  `rpg2k_scene_check.rb`/`rpg2k_logic_check.rb` already do it: `load` the
  split file right after `game.rb`.
