- **LCF codecs**: BER integers, the save's int32 tables and its timestamp double
  are decoded and encoded natively in `mruby-lcf`, so a 32-bit `mrb_int` build
  reads and writes LCF files without `mruby-bigint`. Results are unchanged.
