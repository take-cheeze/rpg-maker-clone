- **bc2cpp**: a return declaration on a method several classes define (POLY)
  could never become a fact: its refusal was memoized the first time a core
  body compiled, while that compile hides the closed world, so every POLY name
  read as "not fully visible". The check now reads the program's world there
  too. `sig/bc2cpp/declarations.rbs` declares the missing sibling definitions
  (`dead?`, `display_max_hp/mp`, `modified_stat`, `refresh_arrows`,
  `build_arrow_sprite`, `set_switch`, `advance`, `build_chipset`,
  `drive_message`, ...) and corrects four traced types that missed a path:
  `Interpreter#set_switch` and `Transition#advance` can return nil,
  `Scene::Map#build_chipset` is `Game::ChipSet?` (its rescue arm), and
  `Screen#update_pan` returns a Float after a Pan Screen.
