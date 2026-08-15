- **An ordinary level change no longer discards a live Change Parameters
  adjustment.** Confirmed against EasyRPG Player's source:
  `Game_Actor::SetLevel` never touches the Change-Parameters mod fields —
  only `Game_Actor::ChangeClass` zeroes them, and only on an actual class
  change. An actor with a Change Parameters bonus (or penalty) who leveled
  up — from battle EXP, the Change EXP command, or the Change Level command
  — previously had the entire adjustment silently discarded, reverting to
  the bare level curve with no indication anything had changed. Change
  Class's own "reset to new level" parameter mode is unaffected and still
  correctly drops any live adjustment when swapping class.
