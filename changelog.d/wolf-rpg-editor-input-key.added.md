- **WOLF RPG Editor (ウディタ/Woditor)** `InputKey`(123)'s "Basic" key kind
  (direction keys/confirm/cancel/sub) now checks or blocks on real player
  input, via a new `WolfRPG::MapScene#input_key_pressed?` and the same
  `Fiber.yield`-per-frame shape `Wait`/`Choices` already use, returning the
  editor's own documented key codes (read straight off its event-command
  window, not reverse-engineered). The direction-keys field and its
  confirm/cancel/sub-key/wait bits are cross-confirmed against the
  wolfrpg-map-parser crate's own `BasicOptions` struct and every real
  `InputKey` command in the sample game's own data. Keyboard-all-keys/
  mouse/gamepad key kinds, 8-way and single-direction modes with no real
  example to check against, and a handful of other capture modes the
  manual documents remain logged and skipped rather than guessed. See
  `docs/adr/0073-wolf-rpg-editor-input-key.md`.
