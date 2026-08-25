- **LCF: field-name lookup tables are shared per record type instead of
  rebuilt per instance.** `LCF::Array1D#initialize` (`mruby-lcf/mrblib/
  lcf.rb`) built a fresh `name -> chunk-id` Hash for `method_missing`
  dispatch on every single decode, even though the schema it was built from
  (e.g. `MAP_EVENT_PAGE`, `mruby-lcf/mrblib/schema.rb`) is a single shared,
  module-level constant identical across every instance of that record type
  -- a map with a few hundred events decoded this same table hundreds of
  times over (once per event page, once more for each page's `:condition`
  sub-table). Now memoized onto the schema itself the first time it's
  needed and reused by every later decode of that record type, with no
  behaviour change (verified: `scripts/rpg2k_scene_check.rb`'s 929 checks
  and `scripts/rpg2k_logic_check.rb`'s 1137 checks both pass unchanged).
