- **Wio Terminal:** a game on the microSD card can bring its palette images
  pre-decoded (`scripts/wio/sd_bitmaps.rb` writes `/rpg2k/wio_bitmaps.bin`).
  The firmware copies each image into the QSPI flash the first time it is
  drawn and draws it from there, as it does a game image's own, instead of
  decoding its PNG into RAM; later boots keep what was copied. Without the
  file, or when an image cannot be copied, it is decoded as before, with a
  `[Wio]` line saying why.
