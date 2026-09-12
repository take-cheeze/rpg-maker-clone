- **A real, measured `wio_rgss_boot` flash/RAM number for `RPGMAKER_BC2CPP=1`
  at its current (~30-round) coverage scope**, not the isolated `.o`/proxy
  estimates each individual coverage round has reported so far. Two real,
  clean `MRUBY_TARGET=wio rake` cross-compiles + `pio run -e wio_rgss_boot`
  links (with and without the flag): flash need grows by **+1,045,440
  bytes** (675,960 → 1,721,400 bytes over the real 507,904-byte budget);
  real static RAM (`.data`+`.bss`, 32,240 bytes) is unchanged either way.
  Essentially the entire flash regression (1,047,376 of 1,045,440 net
  bytes) traces to one file, `mruby-rpg2k-compiled/src/register.o`
  (Game::Picture/EnemyAction's 31 methods) — `mruby-lcf-compiled`/
  `mruby-rgss-compiled` together cost only 36,909 bytes for their own 24
  methods. No code changed; see `docs/adr/0142-bc2cpp-real-wio-flash-ram-
  measurement.md`.
