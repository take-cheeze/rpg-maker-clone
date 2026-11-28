- **Wio Terminal**: more of the code a map, menu or battle frame runs is kept in
  internal flash, chosen from new Renode traces; the list of it
  (`app/wio/qspi_xip_hot.txt`) now names functions in a form that survives
  rebuilds, and the Wio build fails when it has gone stale.
