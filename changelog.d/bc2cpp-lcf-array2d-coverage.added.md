- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 2 of
  `LCF::Array2D`'s own 6 real bytecode-defined methods in
  `mruby-lcf-compiled`: `#[]` and `#[]=` -- the id-keyed table of rows
  every `LCF::File`-family object's project-map tree / database
  item/actor/skill/... list decodes through, each row itself an
  `Array1D` chunk stream decoded lazily. No new opcode work was needed.

  A different method shape from its sibling `LCF::Array1D`, confirmed by
  reading the real source rather than assumed: no
  `#method_missing`/`#respond_to_missing?` exist on this class at all.
  The other 4 real methods stay interpreted, each confirmed against its
  own real generated `#error` marker: `#initialize`'s own
  `(0...LCF.read_ber(s)).each do ... end` (a `Range#each` method call
  taking a block -- not the same on-disk decode shape as
  `Array1D#initialize`'s own `loop`, confirmed directly), `#each`'s own
  `@data.size.times do |i| ... end`, and the private `#read_row_bytes`'s
  own `loop do ... end` are all real `BLOCK`/`S(S)ENDB` opcodes;
  `#to_lcf` takes no arguments at all but hits the same block gap twice
  independently (`@data.each_with_index` then `ids.each`).

  Checked directly against the real embedding diagnostic, not assumed:
  `LCF::Array2D` gets no RData embedding at all -- `@data` (an Array,
  holding raw byte-span Strings until lazily replaced by decoded
  `Array1D` instances) and `@schema` (a Hash) are never Fixnum/Symbol,
  and this class carries no `attr_reader`/`attr_writer`/`attr_accessor`
  at all, so there is no native-accessor/embedded-ivar collision surface
  here either.
