- **The total-EXP ceiling now widens to RPG2003's real 9,999,999, instead of
  staying at RPG2000's narrower 999,999 on every database.** Confirmed
  against EasyRPG Player's source (`Game_Constants::MaxExpValue`): RPG2003
  widens the ceiling by 10x, mirroring the same edition split this engine
  already applies to the max HP cap. On an RPG2003 database (whose own
  default max level is 99, making six-digit-plus EXP totals realistic), an
  actor's total EXP was silently truncated at a tenth of the real cap.
