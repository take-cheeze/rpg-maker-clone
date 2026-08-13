- RPG Maker XP/VX archives bigger than 4 MiB now open on the WebAssembly
  (browser) build. `RGSSAD.open` (`mruby-rpgxp/mrblib/rgssad.rb`, reused by VX
  through `RPGXP::RGSSAD`) reads a whole packed `Game.rgssad` / `.rgss2a` /
  `.rgss3a` into a single mruby `String` up front, before any per-entry
  decryption happens. `build_config.rb`'s Emscripten (and PSP, Wio)
  cross builds define `MRB_STR_LENGTH_MAX` because those platforms fall
  through mruby's `string.c` to a 1 MiB default cap that native
  Linux/macOS/BSD builds never hit; a prior fix raised it to 4 MiB to cover
  large decrypted entries (`rpgxp-rgssad-large-entry.fixed.md`), but a whole
  archive is routinely bigger than any individual entry, so any fixed cap
  just relocates the crash to a bigger file — a real release's 5.5 MiB
  `Game.rgssad` raised `Errno::ENOENT: No such file or directory -
  Data/System.rxdata` at boot, because the archive open failed silently
  (`open_archive`'s rescue logs `[RGSS] failed to open archive ...: string
  too long` and treats it as absent) and no loose `Data/` shadowed it. The
  cap is now disabled outright (`MRB_STR_LENGTH_MAX=0`), matching what mruby
  already does for free on the native platforms.
