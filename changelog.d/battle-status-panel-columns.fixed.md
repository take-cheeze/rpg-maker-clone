- **The RPG2000 battle status panel now draws RPG_RT's own columns**, measured
  off genuine `RPG_RT.exe` under wine: name at contents x=0, condition at 82,
  the `HP` label at 138 and `MP` at 198 (was 4/86/142/202), each gauge a 54px
  run of a 12px label, the current figure right-aligned in an 18px three-digit
  field, a 6px `/` and the maximum right-aligned in another — no space after
  the label. The labels draw from the windowskin's swatch 1 rather than the
  values' swatch 0, and only the current figure recolours (swatch 4 at or below
  a quarter of max, swatch 5 at 0 HP, never for SP). The old
  `"LABEL cur/max"` string with its extra space and 4px-late columns pushed the
  SP column off the panel, leaving `MP 6` where RPG_RT shows `MP600`.
