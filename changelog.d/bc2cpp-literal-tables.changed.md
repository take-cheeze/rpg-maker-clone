- **bc2cpp**: constant Hash/Array literals in compiled class bodies and blocks
  (the `LCF::Schema` tables among them) are built from flash word tables by one
  shared builder instead of per-pair code, cutting about 50 KB of Wio flash.
  `BC2CPP_LITERAL_TABLES=0` restores the old code.
