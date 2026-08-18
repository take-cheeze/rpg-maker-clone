- **RPG2000/2003 maps:** The Flash Screen event command now scales its
  colour/strength parameters (raw database 0..31) to the 0..255 range used
  everywhere else in the engine, matching RPG_RT's own `Flash::MakeColor`
  (`r*8, g*8, b*8, level*8`). Previously the command fed its raw values
  straight through unscaled, so an ordinary Flash Screen — damage flashes,
  warning strobes, RPG2003 Begin-mode strobes — rendered roughly 8x too dark
  and too transparent, nearly invisible instead of the intended color pulse.
  Two existing `scripts/rpg2k_logic_check.rb` checks were using out-of-range
  input values and needed correcting alongside the fix.
