- **CI: a new `android-smoke` job boots the Android debug APK for real, on an
  emulator.** The existing `android` job only ever cross-compiled and
  packaged the APK (`aapt dump badging`, never run) — every real-device
  bug this port has found (the `CHECK(display)` framebuffer gap, the missing
  `Dir` mrbgem, invisible stderr, see `docs/adr/0058-android-port.md`) was
  caught by hand on a `C330`, with no CI coverage of the runtime path at all.
  `android-smoke` (`needs: android`) installs the APK on an x86_64
  `google_apis` emulator under KVM — the Android Emulator's own ARM-binary
  translation runs the arm64-v8a `.so` unmodified, since GitHub-hosted
  runners only get KVM acceleration for an x86/x86_64 guest — pushes
  Nepheshel to the app's fixed game directory, launches
  `RpgMakerCloneActivity` and asserts it reaches the map scene
  (`[RPG2k-MAP]`) with no native crash marker in the device log
  (`scripts/android_smoke_check.bash`). Driving the engine there needs no
  touch-input automation: a new `rpg2k_extra_args` intent-extra hook on
  `RpgMakerCloneActivity#getArguments()` (absent, and a no-op, on every real
  launch) lets the CI job pass the same self-driving flags
  `scripts/rpg2k_boot_check.bash` already uses on desktop
  (`--test_play --rpg2k_new_game --timeout_ms=...`). This is a boot-and-crash
  check, not a performance measurement — real frame-rate numbers still need
  the device, see `docs/android-perf-followups.md`. `continue-on-error: true`
  for now, the same starting point `psp-smoke-game` used before it proved
  stable.
