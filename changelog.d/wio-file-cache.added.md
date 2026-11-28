- **Wio Terminal**: a microSD game's database and maps are copied once into the
  QSPI flash cache that holds its images, and read there in place, so large
  maps load on the 192 KB board from the card too. A cached map is reused only
  after nothing in the game points into it any more. Covered by the
  `wio_image_cache` CTest.
