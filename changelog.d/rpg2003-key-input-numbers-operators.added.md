- **Key Input Processing**'s RPG2003 Numbers/Operators flags now sample real
  keys instead of being decoded and discarded: `RGSS::Input` gained
  `N0`-`N9`/`PLUS`/`MINUS`/`MULTIPLY`/`DIVIDE`/`PERIOD` ids, and
  `Scene::Map`/`Game::Interpreter` resolve a pressed digit or operator to its
  RPG2000 key code the same way the existing button set does. 🚧 Real key
  backing exists on the SDL desktop window backend only (digits from the main
  row or numpad, operators mostly numpad-only) — the PSP, Wio Terminal and
  terminal/sixel native backends leave the new ids unbound, matching how
  `F5`-`F12` are already unbound there.
