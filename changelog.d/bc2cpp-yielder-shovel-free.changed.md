- **bc2cpp closed build:** `Enumerator::Yielder#<<` leaves the closed method table with
  the rest of mruby-enumerator's Fiber machinery. The Enumerator-free proof is no name scan,
  but the list of released methods only took identifier names, so the one operator of the
  group (`<<`, whose Ruby body is `self.yield(*args); self`) stayed bytecode. The host
  method table goes from 1268 to 1267 entries
  (`scripts/bc2cpp/method_table_threshold.txt`).
