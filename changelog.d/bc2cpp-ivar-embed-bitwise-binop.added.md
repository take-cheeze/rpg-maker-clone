- **bc2cpp** now proves an ivar embeddable when every assignment site is a
  `%`/`&`/`|`/`^` send whose two operands are themselves proven Fixnum
  (recursively) and whose operator has no program-wide Ruby override --
  these four never promote a Fixnum result to Bignum, unlike `+`/`-`/`*`
  or `<<`. Verified byte-identical for the real project's own 3 compiled
  gems; the standalone Optcarrot bc2cpp probe gains 4 newly-embedded
  ivars (`Optcarrot::APU#@frame_divider`, `APU::Pulse#@step`,
  `APU::Triangle#@step`, `PPU#@sp_addr`).
