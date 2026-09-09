- **Wio Terminal: strip `$stderr.puts` diagnostic calls from compiled Ruby**
  via a new Ripper-based build step (`strip_wio_debug_output.rb`), wio-only
  -- the checked-in `.rb` source is untouched, so desktop/wasm/psp keep
  every line (including the ones `error_report.rb`'s crash-report tail and
  terminal log console depend on; see ADR 119 for that tradeoff on wio
  specifically). Chosen over a regex/sed pass after finding a real
  multi-line `$stderr.puts` statement in this codebase a line-based match
  would mangle. Real relink: 15,024 bytes of flash and 7,696 bytes of RAM
  recovered; RAM headroom now 158,768 bytes of a 196,608-byte budget. See
  ADR 119.
