- **Image loading** decodes a palette PNG or XYZ into the one block that holds
  its pixels, without a copy of the file or its compressed stream; on the Wio,
  an image file in the QSPI game image is decoded where it lies. Covered by the
  `indexed_decode` CTest.
