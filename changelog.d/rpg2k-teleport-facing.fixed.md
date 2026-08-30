- **A teleport's arrival facing is converted, not passed through raw.** Teleport
  (10810) takes an RPG2003 fourth parameter: the direction to arrive in, 1-based
  over the editor's up / right / down / left, with 0 meaning "keep the current
  facing". The runtime — and `Game::State#direction` — speak RPG2000's 2/4/6/8
  numpad instead, and the raw value was being assigned straight to it. Two of the
  four values (1 and 3, the editor's *up* and *down*) are not directions in that
  convention at all, so they left the party facing something with no movement
  delta and no CharSet row; a third was simply the wrong direction, and only
  "left" lined up by coincidence. Measured on the RPG2003 test-bed
  (`scripts/download-mtf-meido-action.bash`): 25 of its 26 teleports set a
  facing, and 22 of them arrived wrong. An RPG2000 project writes 0 here — the
  edition has no such argument — so Nepheshel's 2021 teleports were unaffected,
  which is why converting unconditionally is the same as a reference
  implementation's version-gating guard for the games that can emit it —
  ported, not independently confirmed against genuine RPG_RT under wine.
