- **The battle damage/HP-recovery popup cap now widens to RPG2003's real
  9999, instead of staying a flat 999 on every database.** Confirmed against
  EasyRPG Player's source (`Game_Constants::MaxDamageValue`): RPG2003 widens
  the ceiling 10x, mirroring the same edition split this engine already
  applies to the max HP cap and total-EXP cap. A single hit, heal, self-
  destruct, or Simulated Attack computing past 999 on an RPG2003 database was
  silently truncated at a tenth of the real cap.
