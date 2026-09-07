- The RPG2003 field **Status** screen now uses the five windows genuine
  `RPG_RT.EXE` lays it out in — actor panel with the FaceSet portrait and the
  front/back row label, gold, HP/MP/EXP, the four battle parameters and the
  five equipment slots — instead of one full-screen window of flowing text,
  with every rect, line and column measured from captures of a genuine
  RPG2003 runtime under wine (kk1.12 + the official RTP). The invented
  `"Class: <name>"` run, the English "State" label and the "Next <n>" EXP
  string are gone; the equipment window now labels its second slot with the
  weapon term for a 二刀流 actor, the way RPG_RT does.
- The RPG2003 field **Order** (party reordering) screen's windows now sit
  where genuine `RPG_RT.EXE` puts them — two 88x80 columns at y=48 with an
  8px gap, centred, and a centred Confirm/Redo prompt at (120,144,80,48) —
  its prompt reads RPG_RT's own 決定 / やりなおし, and all of its text draws
  with the windowskin's palette and shadow instead of flat white. First
  measured this cycle: the screen had never been captured before, and the
  earlier "RPG2003 renders nothing under this wine" note turned out to be
  about one specific game's binary, not the edition.
