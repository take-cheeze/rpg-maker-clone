- `RGSSAD`'s (RPG Maker XP/VX/VXAce archive reader/writer) and `Wolf`'s (WOLF
  RPG Editor) own 32-bit two's-complement helpers no longer spell
  `0xDEADCAFE`/`0xCAFECAFE`/`0x100000000`/`0xffff_ffff`/`0x8000_0000`/
  `0x1_0000_0000` as bare literals. mruby's compiler bakes any literal
  wider than 32 bits into a bignum pool entry regardless of the eventual
  runtime's `mrb_int` width and re-decodes it from its string form on every
  execution of the instruction — real per-byte cost for `RGSSAD#advance`
  (every filename byte and length/size field while parsing a packed
  `.rgssad`/`.rgss2a`/`.rgss3a` archive's entry table, plus every 4 bytes of
  every file's own data in `#decrypt_data`) and for `Wolf::Reader#int`/`#uint`
  (WOLF's own one integer type: counts, ids, command parameters),
  `Wolf::Crypt.v2` (the 2.x `Game.dat`/`*DataBase.dat` XOR scrambler, once per
  byte of the whole file) and `Wolf::Interpreter#fold32` (every Variable
  Operation's own 32-bit wraparound). Same fix as `LCF`'s equivalent
  constants: the values are now computed once, via small-literal `Integer#<<`
  / `#|` at module/class load, instead of reparsed on every call.
