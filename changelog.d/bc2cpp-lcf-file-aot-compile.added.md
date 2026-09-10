- An opt-in (`RPGMAKER_BC2CPP=1`), new-parallel-build-path AOT compiler for a
  hand-picked, provably-safe subset of `LCF::File`/`Database`/`MapTree`/
  `MapUnit`/`SaveData`'s own bytecode methods (`header`/`schema`/
  `terminate_root?`/`rpg2003?`/`maker`/`key?`/`to_lcf`) -- generated at build
  time from the real `mruby-lcf/mrblib/lcf_file.rb` source by the new
  `tools/bc2cpp/bc2cpp.rb`, and swapped in over the interpreted bytecode by a
  new `mruby-lcf-compiled` gem. Off by default for every target; the ordinary
  interpreter (`mruby-lcf`) is the unconditional fallback for everything this
  doesn't cover. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
