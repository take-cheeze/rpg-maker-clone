- **Wio Terminal: stripped the dead default-font directory scan.**
  `mruby-rgss/src/default_font.cxx`'s `opendir`/`readdir`-based search
  (backed by a `std::vector<std::string>` of candidate directories) was
  compiled and run unconditionally, but wio's own bare newlib has no
  `dirent` at all (already stubbed to always fail there) and nothing on
  wio ever registers a search directory in the first place -- the search
  was guaranteed to resolve to "not found" every time. Gated the real
  implementation behind the same `WIO_TERMINAL` macro `profiler.cxx`
  (ADR 125) already uses; a two-line stand-in keeps `default_font_path()`
  returning the same `""` it always returned there.
  Real ARM cross-compile of this one file: 1,608 -> 90 bytes of `.text`.
  See ADR 126.
