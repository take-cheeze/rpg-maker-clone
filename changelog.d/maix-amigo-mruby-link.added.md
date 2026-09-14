- **Maix Amigo interpreter link**: the `maix_rgss_boot` firmware links the
  cross-built `libmruby.a` plus LVGL (RAM 1.8%, flash 37.2%) and boots the
  interpreter on the chip -- `mrb_open`, a string eval, heartbeat -- proven
  under Renode by CI's `maix-smoke` job, which now boots this environment
  instead of the P0 one. Both firmwares upload as artifacts. See
  `app/maix/README.md`.
