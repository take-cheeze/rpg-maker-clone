- **Wio under Renode plays real game data**: `scripts/wio/renode_game.bash`
  packs a game directory into an image mapped at the QSPI flash window, boots
  the new `wio_renode_game` firmware (192 KB of RAM; `wio_renode_game_big` has
  16 MB) and runs title, New Game, the map and an optional headless battle,
  printing heap and stack use per phase and failing unless the run finishes.
