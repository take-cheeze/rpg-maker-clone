- **The battle damage/HP-recovery popup cap now widens to RPG2003's real
  9999, instead of staying a flat 999 on every database.** Ported from
  a reference implementation's damage-cap constant, not independently
  confirmed against genuine RPG_RT under wine: RPG2003 widens
  the ceiling 10x, mirroring the same edition split this engine already
  applies to the max HP cap and total-EXP cap. A single hit, heal, self-
  destruct, or Simulated Attack computing past 999 on an RPG2003 database was
  silently truncated at a tenth of the real cap.
