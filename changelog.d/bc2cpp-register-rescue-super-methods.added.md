- **bc2cpp**: register 104 newly-compilable methods unlocked by RESCUE/SUPER
  support (docs/adr/0145/0146) -- 102 in `mruby-rpg2k-compiled`
  (`Game::States.singleton#row`, `Game::Actor#two_handed?`,
  `Game::Actors#[]`, 8 `Game::Interpreter` handlers, 7 `RPG2k` helpers, 4
  `RPG2k::Scene::Base`, both `#play_sound`s, `EventResolver#map_event_commands`,
  3 `RPG2k::Scene::Battle`, `DebugMenu`/`ItemMenu`/`Menu` `#initialize`s plus
  both `#load_face_bitmap`s, `Game::Party#equip_by_class?`,
  `Game::State.singleton#ole_now`, `MapViewer`/`ChipsetEditor` `#save_to_disk`
  plus `MapViewer#build_chipset`, both `SkillMenu` gaps, 6
  `RPG2k3::Scene::Battle` SUPER methods, 13 `Title`, `GameOver`/`StatusMenu`/
  `SaveLoad` gaps, and 38 `RPG2k::Scene::Map`) and 2 in
  `mruby-rgss-compiled` (`RGSS.singleton#_comparison_sign`,
  `RGSS::Graphics.singleton#render_fps`) -- plus the wio companion fixes
  this unlocks: a `:SYM`-node case in `strip_wio_bc2cpp_stubs.rb`'s own
  argument reader (CRuby 3.4 shapes Symbol args differently than older
  versions) and a `scene/map.rb` companion-statement split.
