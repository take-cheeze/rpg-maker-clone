- Add opt-in decoded-tree reuse for bc2cpp generation comparisons, with private
  restores, input-sensitive keys and atomic checksummed snapshots. It defaults
  off because cold parallel generation regressed; canonical source paths allow
  the engine compiled gems to share their world.
