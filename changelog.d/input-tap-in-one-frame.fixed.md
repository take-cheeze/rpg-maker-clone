- A key that is pressed and released between two frames is no longer swallowed.
  Key transitions arrive in a buffer that `Graphics.update` drains once a frame
  — the SDL keyboard watch, the browser build's on-screen keypad, the terminal
  backends — and `RGSS::Input.release` cleared the key's *trigger* along with
  its held state, so when a tap delivered both its press and its release into
  the same drain the game saw a key that had never been pressed. A quick tap on
  the browser keypad now registers, as does a synthesised key that lands on a
  long frame. `Input.update` still clears every trigger at the end of the frame,
  so no trigger outlives the frame it arrived in.
