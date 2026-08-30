- **Title screen:** The cursor always starts on New Game, whether or not a
  save exists — a prior fix here had it start on Continue whenever a save
  exists, sourced only from a reference implementation's behavior rather
  than genuine RPG_RT; confirmed against a genuine RPG_RT.exe that this was
  wrong, and reverted. A save's presence still
  ungrays Continue, it just does not move the initial cursor.
