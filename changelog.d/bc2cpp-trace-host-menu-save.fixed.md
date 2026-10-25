- **bc2cpp**: seven wrong trace-derived return hints (`%a{bc2cpp:hint}`) are gone. A strict-hints closed build
  raised `BC2cppHintViolation` on them outside the traced paths:
  - `Game::Screen#approach` returns a Float during a slow screen pan.
  - `Game::Interpreter#do_control_vars` / `#do_control_switches` return a Range.
  - `RPG2k::Scene::Map#page_field` returns an `LCF::Array1D`.
  - `#build_events` returns nil for a map without events.
  - `#apply_location_requests` returns an Array.
  - `Game::Screen#erase` returns nil.
- `scripts/bc2cpp/trace_host.cxx` takes `BC2CPP_HOST_KEYS` (scripted key taps), `BC2CPP_HOST_PREVIEW_MAP` and
  `BC2CPP_HOST_CONTINUE`, so a verify-mode trace can reach the menu, save and load scenes.
