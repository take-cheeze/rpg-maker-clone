- **Maix Amigo virtual gamepad**: since the board has no physical buttons,
  `maix_game`/`maix_game_sd` now draw a translucent D-pad plus Confirm/Cancel
  outline overlay (`app/wio/src/maix_gamepad.cxx`) on top of the game, and
  touch is hit-tested against the same regions
  (`app/wio/src/maix_gamepad_layout.h`) to drive `RGSS::Input` instead of
  every tap meaning Confirm. The touch coordinate transform is derived, not
  yet confirmed against a real finger on real hardware -- `rgss_maix_poll`
  prints the raw touch and resolved key on every press to make that check
  possible without a camera on the device.
