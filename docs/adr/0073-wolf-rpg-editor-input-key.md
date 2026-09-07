# 73. WOLF RPG Editor InputKey(123): the "Basic" key-input mode

Date: 2026-09-07

## Status

Accepted

## Context

`InputKey`(123) -- "キー入力" (help/04ev_keyinput.html) -- covers four
distinct "キー種" (key kinds) selectable in its own editor window: "基本"
(Basic: direction/confirm/cancel/sub), keyboard-all-keys, mouse
clicks/coordinates/wheel, and gamepad buttons, each its own sub-mode with
its own argument shape (the wolfrpg-map-parser crate models this as a
`State` enum of `Basic`/`KeyboardOrPad`/`Mouse` structs). Only "Basic" is
implemented here: every one of the 58 real `InputKey` commands in the
sample game's own data is this kind (Basic mode is what the RPG Basic
System's own menus, message boxes and walk-key handling all use), and 54
of those 58 share one argument shape this reader could cross-check byte by
byte -- `[target, options]`, options packing (matching the crate's own
`BasicOptions` struct) a direction-keys mode in the low nibble, confirm/
cancel/sub-key enable bits, and a "wait until pressed" bit.

The direction-keys nibble is an *enum*, not a bitmask (the crate's own
`DirectionKeys`: 0 none, 1 all four cardinal, 2 all eight incl. diagonal, 3
-6 a single direction each, 7 up/down, 8 left/right) -- but real command
dumps only ever carry 0, 1, 7 or 8; the rest (8-way, and each single-
direction value) have no real example to check the crate's own enum
against, so they are logged and skipped rather than assumed correct by
extension.

The returned key codes themselves are not reverse-engineered at all:
help/Ev_keyinput.png (the editor's own event-command window, screenshotted
directly into the manual) labels them outright -- 決定(10) confirm,
キャンセル(11) cancel, サブキー(12) sub, and "方向キー 4方向(2,4,6,8)"
for the direction keys' own numpad-style codes -- and documents the Basic
mode's own default key bindings (Enter/Space confirm, Esc/Backspace/Delete
cancel, Shift sub) that `WolfRPG::MapScene#input_key_pressed?` maps
directly onto `RGSS::Input::C`/`B`/`SHIFT`.

## Decision

- `Wolf::Interpreter#input_key_candidates(options)` decodes the confirmed
  direction-keys values into a list of `:up`/`:down`/`:left`/`:right`
  symbols (empty for "none"), appending `:confirm`/`:cancel`/`:subkey` per
  their own enable bits; `nil` for an unconfirmed direction-keys value.
- `Wolf::Interpreter::Run#exec_input_key` requires exactly 2 arguments (the
  confirmed Basic-mode shape); checks every candidate key each frame it has
  something to report, in that fixed order, and assigns the *first* match's
  own documented code to the target -- immediately once, or every frame
  (via `Fiber.yield`, the same blocking shape `#exec_wait`/`#exec_choices`
  already use) until one is found, per the "wait until pressed" bit. `0`
  when nothing is currently down and the call is not in wait mode, matching
  the manual's own documented "何もなければ0が代入されます".
- A 3-argument call (4 real examples, all `option`+`0` byte-1-nonzero
  shapes this reader has not placed), an unconfirmed direction-keys value,
  and every non-Basic key kind (no separate discriminator field for those
  has been found in this reader's own framing, and none is exercised by
  any real command in the sample game either) are logged and skipped.

## Consequences

- Booting the real binary against the sample game: the title screen's own
  `InputKey` call (checking for the cancel key, per `CE#48`'s own basic-
  system initialization) no longer logs as unimplemented.
- Custom key-binding overrides (help/04ev_keyinput.html's own "システム
  変数52～57で...設定した" mechanism) are not modeled -- confirm/cancel/sub
  always read their documented default bindings.
- Still unimplemented: keyboard-all-keys, mouse, and gamepad key kinds; the
  3-argument Basic-mode variant; 8-way and single-direction modes; the
  "新押し時のみ取得"/"離した時のみ取得"/"押し続けフレームを得る" capture
  modes the manual documents beyond plain press-state and wait (this
  reader's own `#input_key_pressed?` is a level check throughout, matching
  only the two modes real data exercises).
