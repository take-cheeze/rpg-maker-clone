- **CI:** the `bc2cpp-build` job caches the libclang facts behind
  `scripts/native/binding_split.rb check` (`actions/cache`, keyed on the Nix
  pin, mruby headers, RGSS sources and the extractor), so warm runs skip the
  ~48s extraction and its `nix develop .#clang` shell. `base_section_check.rb`
  takes `--jobs`, and CI passes 4.
