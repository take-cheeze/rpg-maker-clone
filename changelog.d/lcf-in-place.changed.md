- **Wio Terminal**: the database and the maps of the QSPI game image are read
  where they lie in flash, with no heap copy (`LCF.mapped_file`). A map layer is
  read in place until its first write. Map 194, with two 32,000-byte layers, now
  loads on the 192 KB board.
