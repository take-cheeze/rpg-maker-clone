- `scripts/bc2cpp/trace_host.bash` builds a headless host
  (`scripts/bc2cpp/trace_host.cxx`) for the closed bc2cpp `libmruby.a`. It
  boots RPG2000 Nepheshel into New Game and runs bounded frames, and with a
  `BC2CPP_TRACE_TYPES=1` build it writes the `PARAM_`/`RETURN_` trace dump.
  Documented in `docs/bc2cpp-trace-host.md`.
