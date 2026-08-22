- **Battle Item/Skill lists:** Now a genuine two-column grid, matching
  RPG_RT's `Window_Item`/`Window_Skill` (`column_max = 2`). Down/Up move by
  a row and stop rather than wrap past either end, and Right/Left now work,
  moving one cell at a time across row boundaries. Previously these lists
  behaved as a single wrapping column with no Right/Left handling at all.
