- **Wio Terminal**: the database and the maps of the QSPI game image are read
  where they lie in flash, with no heap copy (`LCF.mapped_file`). A map layer is
  read in place until its first write, so a map no longer needs a heap block the
  size of a layer or of its event table.
