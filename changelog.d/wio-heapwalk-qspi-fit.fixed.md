- **Wio heapwalk firmware**: a heap-peak snapshot taken inside `malloc` no
  longer reaches mruby code in the QSPI flash, so `wio_renode_game_heapwalk`
  passes `scripts/wio/qspi_xip_check.rb`. The `wio` CI job now links it and
  checks both Renode game firmwares.
