- **CI** plays a synthetic game from a simulated microSD card under Renode on
  the 192 KB Wio Terminal board (`wio-renode`): the QSPI image cache's first
  copy, a reboot that finds it, and the PNG fallback without the pack.
  `wio_renode_game` logs the cache's hit and miss counts at the end of a run.
