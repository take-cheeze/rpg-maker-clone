- Internal: bc2cpp reads the schema for a literal-key read on an exact LCF file
  (`unit[:lower_layer]` on `LCF::MapUnit`). When the schema field is an
  Array, the read is an Array for class layout, so an ivar that stores it can
  be typed. Nothing changes for other reads or for programs that do not use
  these LCF files.
