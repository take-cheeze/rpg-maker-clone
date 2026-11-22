- **mruby-lcf**: in builds with compiled gems (wio included) `LCF::Schema` lives in flash. `mruby-lcf/gen_schema_rom.rb`
  writes its 1,030 Hashes as constant tables (about 20 KB); Ruby holds each as a handle (`mrblib_rom/schema.rb`) and
  the readers go through `LCF.sget`/`LCF.skeys`, so none of the Hashes (about 28 KB of 32-bit heap at boot and 47 KB
  more as record types are read) is built. `BC2CPP_ROM_SCHEMA=0` keeps the Hashes.
  `scripts/bc2cpp-rpg/lcf_schema_rom_check.rb` checks the tables against `schema.rb` and that only the readers touch a
  schema value.
