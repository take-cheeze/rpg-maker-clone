- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers all 4 of
  `LCF::Sections`'s own real bytecode methods (the sequential-section
  container `LCF::File#initialize` builds for a multi-section schema, e.g.
  `LCF::MapTree`'s map-properties table plus tree order/party positions):
  `#initialize`, `#add`, `#key?`, `#[]`. Added to `mruby-lcf-compiled`,
  needing zero new opcode work and finding zero live `bc2cpp.rb` bugs.
  `#[]`'s own `idx.is_a? Symbol` guard compiles to the same generic
  `mrb_funcall`-plus-JMPNOT fallback every other `x.is_a? Foo` guard in
  this codebase already takes. `@by_name`/`@list` are a Hash and an Array
  (never Fixnum/Symbol), so nothing on this class is embeddable.
  `#method_missing`/`#respond_to_missing?` stay interpreted, same as every
  other method_missing-using class here. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`.
