- **Android:** the game picture is centred in the phone-shaped window.
  mruby-rgss now hangs every game-side object off one style-less *game root*
  container instead of the active screen (`parent_object` / `vp_init`), and the
  Android shell centres that root in the display's letterbox on boot and on
  every resolution change (`src/android_vpad_ui.cxx`), instead of pinning the
  4:3 picture to the top-left corner with black bands only right and bottom.
  Other backends leave the root at (0,0), where it renders nothing.
