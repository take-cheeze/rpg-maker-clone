- **Field menu:** the party-status panel now shows each member's EXP —
  current over the next level's absolute threshold (`EXP 77/128`), same as
  the field Status screen's own EXP row — under Lv/HP/MP, with the same
  `---` stand-in at an actor's max level. Previously this row didn't exist
  at all: opening the menu showed only name/condition and Lv/HP/MP, with no
  EXP anywhere on the panel. Confirmed against a genuine RPG_RT.exe
  screenshot (Nepheshel): its own field-menu party panel draws an "EX" row
  for every member that this build was missing entirely. The panel's
  per-actor row grew from 40 to 48px to fit the third line.
