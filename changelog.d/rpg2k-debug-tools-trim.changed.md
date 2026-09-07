- The psp and wio mruby cross builds no longer compile RPG_RT's own Test
  Play-only debug tools (the F9 debug menu, its chipset passability editor,
  and its whole-map viewer) into `mruby-rpg2k` — a released game never
  reaches any of them (`RPG2k#test_play` gates every real call site), so
  these two flash-constrained targets drop 18,259 bytes of bytecode they
  never call. Desktop, wasm and Android are unchanged. See ADR 97.
