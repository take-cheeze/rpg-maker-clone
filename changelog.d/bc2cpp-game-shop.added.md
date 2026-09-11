- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 11 of
  `Game::Shop`'s own 14 real bytecode methods (the RPG2000 buy/sell
  shop-menu backing model: stocked goods, buy/sell affordability, the
  99-item stack cap, half-price selling). Added to `mruby-rpg2k-compiled`.
  No new opcode work was needed -- the remaining gaps are `#initialize`'s
  own Ruby block and `#buy`/`#sell`'s own non-mandatory argument, both
  already-established out-of-scope shapes. Also confirms a real, live
  instance of the native-method-name-collision shape a prior round's
  devirtualization-registry fix protects against: `Game::Shop#name`
  collides by bare name with mruby core's own `Symbol#name`/`Class#name`,
  and is correctly never devirtualized into from any compiled call site.
  See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
