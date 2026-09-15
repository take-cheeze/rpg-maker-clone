- **Maix Amigo display, input and SD layers**: PIO-side LVGL display HAL
  (full-frame RGB565, proven by a red frame through the capture rig),
  FT6X36 touch scan plus the `RGSS::Input` bridge (wired into `input_poll`),
  and an opt-in SD newlib-syscall layer (compile-proven in CI, runtime
  needs hardware). See `app/maix/README.md`.
