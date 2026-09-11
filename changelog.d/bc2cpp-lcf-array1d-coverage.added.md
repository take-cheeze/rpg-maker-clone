- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 5 of
  `LCF::Array1D`'s own 11 real bytecode-defined methods in
  `mruby-lcf-compiled`: `#[]`, `#key?`, `#int16_values`, `#delete`, and
  `#[]=` -- the sequential chunk-id-to-raw-bytes record every
  `LCF::File`-family object (`Database`/`MapTree`/`MapUnit`/`SaveData`)
  decodes through. No new opcode work was needed.

  The other 6 real methods stay interpreted, each confirmed against its
  own real generated `#error` marker rather than assumed from the Ruby
  source shape: `#initialize`'s own `loop do ... end` and the private
  `#sym2idx`'s own `.each { |k, e| ... }` are both real `Kernel#loop`/
  `Enumerable#each` method calls taking a block (`BLOCK`/`S(S)ENDB`
  opcodes) -- not the already-supported `while`/`until` JMP/JMPNOT
  back-edge shape, a distinction checked directly rather than guessed;
  `#to_lcf`/`#respond_to_missing?` each carry one optional argument, and
  `#method_missing` a rest argument.

  Checked directly against the real embedding diagnostic, not assumed:
  `LCF::Array1D` gets no RData embedding at all -- `@data` (an Array of
  Strings) and `@schema` (a Hash, per its own pre-existing
  `# bc2cpp: (, Hash)` annotation) are never Fixnum/Symbol, so nothing on
  this class was ever an embedding candidate regardless of the eighth
  severe bug's own `attr_reader`/embedded-ivar collision fix
  (`attr_reader :schema` exists on this class, but never collides with
  anything embedded).
