- **Android native build support**, additive to and independent of the
  desktop/wasm build: a Gradle/CMake project under `app/android` cross-compiles
  the full runtime (mruby, LVGL, SDL2/SDL2_mixer, gflags, ng-log, uni-algo,
  quickjs-ng) into a real, installable debug APK via SDL2's Java `Activity`
  glue, using the same root `CMakeLists.txt` the desktop/wasm builds already
  use rather than a fork of it. Bring-up scope: one ABI (`arm64-v8a`), no
  in-app project picker (`adb push` a project to a fixed external-files
  directory, mirroring the PSP port's fixed Memory Stick path), and RPG Maker
  MV/MZ's WebGL renderer stays off (a real EGL symbol gap, not a missing
  feature) — untested on a real device or emulator, none being available in
  the environment this port was built in. See `app/android/README.md` and
  `docs/adr/0058-android-port.md`.
