- **The uni-algo Unicode tables are trimmed to the modules this project
  actually calls.** The whole codebase uses exactly three uni-algo features —
  UTF conversion (`una::utf32to8` / `una::utf8to32u`), the UTF-8 decoding view
  (`una::views::utf8`) and NFD normalisation (`una::norm::to_nfd_utf8`) — but
  every build was compiling in the case-mapping, collation, code-point
  property, script, grapheme/word segmentation and compatibility (NFKC/NFKD)
  normalisation tables alongside them. `cmake/uni-algo-trim.cmake` switches
  those modules off on the CMake `uni-algo` target and `build_config.rb`
  mirrors the same list into the mruby cross-builds, so the gems that include
  uni-algo's headers agree with the library they link. Measured on the PSP
  EBOOT: the `una::detail::*` tables fall from 663 KB to 145 KB and the
  loaded read/execute segment by 517,920 B — on that target this is **~506 KB
  of live RAM**, not just image size, because the loader maps every PT_LOAD
  segment into the console's ~24 MB at launch (ADR 0047's P6). Desktop and
  wasm shed the same tables from their binaries, and it is the `uni-algo` half
  of ADR 0007's P2 flash-fitting lever for the Wio Terminal, which takes
  effect there once that port links `libmruby.a`. No behaviour change: the
  disabled modules are `#ifdef`-gated in uni-algo's own headers, so a call to
  one would be a compile or link error rather than a silent difference, and
  the `RGSS.to_nfd` test still passes.
