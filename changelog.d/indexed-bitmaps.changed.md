- **Palette graphics stay 8-bit in memory.** A colour type 3 PNG or an XYZ
  file is kept as one byte per pixel plus its palette until something draws
  into it, instead of 4 bytes per pixel: about a quarter of the memory for
  chipsets, charsets, faces, pictures, panoramas and battle graphics, with the
  same pixels on screen. `RGSS_INDEXED_BITMAPS=0` (environment or build
  define) turns it off.
