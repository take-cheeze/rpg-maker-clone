- **bc2cpp**: enemies no longer fight with `nil` attack, defence, agility and
  max HP in `RPGMAKER_BC2CPP=1` builds. An `attr_reader` with 15 or more names
  is packed into an array by mrbc, and the generator dropped every name, so
  `Game::Enemy`'s stats were moved into the embedded struct behind mruby's
  native readers. Packed calls are now read, and a real splat is refused.
  See ADR 0206.
