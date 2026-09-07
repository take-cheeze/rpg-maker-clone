- The map-walk port's export format (ADR 61/91) stores a tile pixel as one
  palette index instead of a 16-bit colour, with the palette carried in
  `map.bin` — which is what an RPG Maker chipset already is, so the picture
  is byte-for-byte identical while the atlas halves again. The iPod nano 7G
  app's `.bss` drops from 214 KB to 150 KB (336 KB when the port landed), and
  the Wio Terminal's `wio_walk` firmware now takes a **96x96** map with 192
  atlas entries — 2.25x the area it accepted before, which brings 23 of
  Nepheshel's 29 over-64x64 maps within reach — in *less* SRAM than its old
  64x64 cap cost. Format version 3: re-export before installing. See
  ADR 92.
