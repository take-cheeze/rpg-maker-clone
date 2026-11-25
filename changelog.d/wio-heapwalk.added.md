- **Wio heap snapshots**: `scripts/wio/renode_game.bash --heapwalk DIR` with the
  `wio_renode_game_heapwalk[_big]` firmware saves the heap at each phase and each
  scene's peak, and `scripts/wio/heapwalk_report.rb` breaks it down by owning
  object, allocating function and block size.
