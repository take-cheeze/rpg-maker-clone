- Internal: bc2cpp types an ivar stored from `unit[:key] || []` on an exact LCF
  map unit as an Array when the schema says the field is an Array. The layer
  ivars `Game::Map#@lower` and `@upper` were poisoned by this join before, and
  now are typed. Other ivars and programs are unchanged.
