- **Android:** on-screen touch controls. With no keyboard or gamepad attached,
  touch positions map onto RGSS keys by window zone in `src/sdl_input.cxx`:
  the left 40% is a floating D-pad (direction read from each drag's offset
  against its own touch-down anchor, diagonals included), and the right side
  splits into B/cancel (upper) and C/confirm-A (lower) at half height. Each
  finger keeps its own role, so steering while tapping works. Confirmed on
  device with Nepheshel: title menu, opening-demo choice and map walking all
  play by thumb.
