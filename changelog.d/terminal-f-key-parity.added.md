- **The terminal/sixel backend (`--iterm`/`--sixel`) now binds F5-F9 and F12**,
  matching the SDL desktop backend (`src/sdl_input.cxx`) — previously only F9
  and F12 were read from the CSI escape sequence a terminal sends for a
  function key, so F8's new bug-report hotkey (and any future F5/F6/F7 use)
  silently did nothing there. The on-screen control legend now lists `F8` for
  Bug report alongside the existing Test Play debug-key hint.
