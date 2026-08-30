- RPG Maker 2000: an attack carrying both a **weapon-type and a magic-type**
  elemental attribute at once now scales damage correctly. A reference
  implementation's attribute-multiplier logic keeps the strongest rate *within*
  each type (physical/weapon and magical/magic tracked independently) and,
  when both are present, **multiplies** the two as successive percentage
  scalings of the damage (200% × 50% nets 100%, not an average and not just
  the single strongest rate across every attribute regardless of type — the
  previous behaviour), ported from that reference and not independently
  confirmed against genuine RPG_RT under wine.
  `Game::Battle#apply_attr_multiplier` (renamed from
  `#attr_multiplier`, which returned a percentage the caller then applied —
  the truncation order between that and the two-step scaling isn't always
  the same, so it now takes and returns the actual damage figure, matching
  that reference's own signature) reads each attribute's type
  off the same `property` table `#attr_rate` already uses. Covered by new
  `scripts/rpg2k_logic_check.rb` checks.
