- **RPG2000/2003 messages:** An out-of-range `\c[n]` colour code (n > 19,
  the highest real palette slot) now resets to colour 0, matching real
  RPG_RT — previously it stayed out of range and fell back to a flat,
  non-blended approximation colour instead of the windowskin's own shaded
  swatch, a visibly different colour for almost any custom windowskin.
  A variable-driven `\c[\v[n]]`/`\s[\v[n]]` also now resolves the nested
  variable correctly, the same way `\n[]`/`\v[]` already did — previously
  it silently misread the literal escape text as a raw number instead.
  Covered by two new `scripts/rpg2k_logic_check.rb` checks.
