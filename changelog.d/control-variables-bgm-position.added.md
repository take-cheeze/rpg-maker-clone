- **Control Variables' "Other" operand now supports selector 8 (BGM play
  position)**, reading `RGSS::Audio#bgm_pos` (milliseconds into the current
  track, already used by the "BGM played once" Conditional Branch) the same
  way EasyRPG's `ControlVariables::Other` reads `Audio().BGM_GetTicks()` --
  base-engine behaviour, not gated behind the Maniac Patch like the
  selectors above it. Previously read as 0, silently.
