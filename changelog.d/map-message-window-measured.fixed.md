- **RPG2000 map message window and Show Choices**, measured off genuine
  `RPG_RT.exe` under wine for the first time (its geometry had been inferred
  since ADR 0021 pinned the 320x80 panel). A FaceSet portrait is now drawn
  inset 8px into the window contents instead of flush in the corner, and it
  reserves 72px of text width on its own side, so left-hand-face text starts
  further right and an overlong line no longer runs over a right-hand-face
  portrait; message text stops 3px short of the contents edge; Show Choices
  labels are indented 12px past the message text column and their cursor is
  drawn 2px inside the contents area rather than 4px outside it; the window
  unrolls over 8 frames, not 7; and a Show Choices that directly follows a
  Show Text now appears with no keypress at all — and only when its options
  still fit the window's four rows, otherwise the text page takes one confirm
  and the options replace it on a page of their own.
