- **New Game now works in the browser again.** `LCF.read_ber` folded a BER
  integer's sign with `[ret].pack('L').unpack1('l')`, but on a target whose
  `mrb_int` is 32-bit (the Emscripten/browser build, Wio, PSP) every value with
  bit 31 set is a bignum by then and `pack` cannot convert it back, so decoding
  raised `RangeError: integer out of range`. The first event command carrying a
  `-1` parameter tripped it, which is one command list into any real project:
  the browser reported `Failed to start new game: integer out of range` and sat
  on the title screen. The sign is folded arithmetically now; covered by a new
  `mruby-lcf` test over the signed 32-bit extremes.
