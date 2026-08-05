- The `3rd/timidity` submodule (TiMidity++ 2.15.0) is removed. It was never
  built: ADR 0006 weighed linking it for MIDI playback and chose SDL_mixer
  instead, which carries its own TiMidity codec, so nothing in `CMakeLists.txt`,
  `platformio.ini`, `flake.nix`, `build_config.rb` or any source file ever
  referenced it. It was 8.4 MiB of GPL autoconf application that every clone and
  every CI checkout paid for and no build consumed. The ADR references to it are
  left as written — they record what was considered at the time.
