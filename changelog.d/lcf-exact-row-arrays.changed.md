- **Wio Terminal**: the database's table row indexes are sized to their row
  count, so they no longer leave up to half of their slots unused. That frees
  about 5 KB of heap for the whole run.
