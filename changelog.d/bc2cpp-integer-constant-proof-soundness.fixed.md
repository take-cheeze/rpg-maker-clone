- **bc2cpp's `INTEGER_CONSTANT_PROOF` no longer admits a constant that is not
  an Integer** (docs/adr/0324): a name defined natively (`mrb_define_const`,
  `mrb_define_global_const`, `mrb_define_const_id`, `mrb_const_set`) is now
  withdrawn, as the old scan's lazy window matched no name at all, and a
  `SETCONST` that a conditional jump lands on (`X = c || 1`, `X = c && 1`) is
  no longer an Integer definition. A Float, nil or String constant used as an
  Integer operand compiled to garbage (`nil + 1` gave `1`). In the shipped wio
  closed world only `Game::Variables::MAX`/`MIN` (bare names shared with the
  native `Float::MAX`/`MIN`) lose their inlined value; behaviour is unchanged.
