- **bc2cpp's compiled gems table is a config file.** The per-gem data of
  `BC2CPP_COMPILED_GEMS` (each gem's `OUT_SYMBOL`, `native_namespaces` and where
  its owners come from) moved from `tools/bc2cpp/compiled_gems.rb` to
  `tools/bc2cpp/compiled_gems.yml`, with the design-rule comments. Owners stay
  derived (`owners_from: mruby-rgss` or `core`). The file is validated on load
  (unknown keys, missing or duplicate `out_symbol`, bad owners source fail
  loudly) and by `scripts/bc2cpp/compiled_gems_config_check.rb`; the loaded
  table is identical, key order included. See `docs/bc2cpp-compiled-gems.md`.
