- **Control Variables' "Other" operand now supports selector 8 (BGM play
  position)**, reading `RGSS::Audio#bgm_pos` (milliseconds into the current
  track, already used by the "BGM played once" Conditional Branch) the same
  way a reference implementation's own "other" Control Variables operand
  reads the BGM tick count (ported from that source, not independently
  confirmed against genuine RPG_RT under wine) --
  base-engine behaviour, not gated behind the Maniac Patch like the
  selectors above it. Previously read as 0, silently.
