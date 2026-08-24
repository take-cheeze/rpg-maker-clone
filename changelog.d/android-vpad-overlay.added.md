- **Android:** the touch zones are now drawn: a visible virtual gamepad
  (`src/android_vpad_ui.cxx`) mirrors `src/sdl_input.cxx`'s layout on LVGL's
  top layer -- a D-pad cross bottom-left, B (cancel) and C (confirm-A) circles
  on the right, translucent so the scene shows through, each control
  highlighting while its key is held. The widgets are affordance only; input
  still flows through the finger-zone logic, so tapping anywhere in a zone
  works exactly as before, drawn button or not.
