- `tools/optcarrot_probe/README.md` documents why `Optcarrot::CPU`'s own
  6502 register file (`@_a`/`@_x`/`@_y`/`@_sp`/`@_pc`, and the split flag
  register `@_p_c`/`@_p_d`/`@_p_i`/`@_p_nz`/`@_p_v`) stays outside the 3
  ivars (`@clk_total`, `@jammed`, `@ppu_sync`) `BC2CPP_SELF_REGISTERING`
  newly lets embed: traced by hand against `cpu.rb`'s own SETIV sites and
  `IvarLayout.trace_type` (`tools/bc2cpp/bc2cpp.rb`), every register ivar
  has at least one assignment sourced from `@data`/`@addr`, which are
  themselves set from plain `SEND`s (`fetch(...)`) that
  `IvarLayout.trace_type`'s `SEND` case has no general "proven
  Fixnum-returning" rule for -- that proof exists elsewhere in the file
  (`CodeGen#compute_fixnum_return_names`) but runs strictly after
  `IvarLayout.analyze` already returned, so using it here would mean
  merging the two into one shared fixed point rather than the current
  one-directional pipeline. No code changed; this documents a real,
  hand-verified architectural boundary for whoever picks this up next,
  rather than leaving the "next concrete target" note stale.
