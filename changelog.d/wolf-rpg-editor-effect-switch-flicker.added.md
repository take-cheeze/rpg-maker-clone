- **WOLF RPG Editor (ウディタ/Woditor)** `Effect`(290)'s Picture-target
  `SwitchFlicker` — "点滅A[明滅]" — now persistently alternates a
  picture's color between its base state and base+RGB every N frames,
  stopping on an all-zero RGB delta or a zero frame count, the same
  per-frame-ticked animation shape `ChangeColor`(151)'s own screen tone
  transition already established. See
  `docs/adr/0083-wolf-rpg-editor-effect-switch-flicker.md`.
