# Android

A Gradle/CMake project that runs the RPG Maker 2000/2003/XP/VX/VX Ace runtimes
on Android via SDL2's Java `Activity` glue.

This is additive to and independent of the desktop CMake build — building the
APK does not touch the desktop/wasm builds, and vice versa. Its
`externalNativeBuild` points straight at the repo root
[`CMakeLists.txt`](../../CMakeLists.txt) (the same file the desktop/wasm
builds use, with its own `ANDROID` branches doing the platform-specific work),
so there is one build description, not a fork of it. The design is in
[`docs/adr/0058-android-port.md`](../../docs/adr/0058-android-port.md).

## Status: native build bring-up — untested on a device or emulator

This produces a real, installable debug APK (verified with `aapt dump
badging` and `unzip -l`) that packages `libSDL2.so`, `libSDL2_mixer.so` and
`librpg_maker_clone.so` (mruby, LVGL, gflags, ng-log, uni-algo and
quickjs-ng all linked statically into the latter). It has **not** been run on
a real device or an emulator — none was available in the environment this
port was built in — so anything past "it links and packages" (does the window
actually appear, does input work, does audio play) is unconfirmed. See the
ADR's Consequences section for the full list of what is bring-up-scope only.

## Building

Requires:

- An Android SDK with API 34 platform + build-tools installed
  (`ANDROID_HOME`).
- NDK 27.2.12479018 (`app/build.gradle`'s `ndkVersion`) — installable via
  `sdkmanager --install "ndk;27.2.12479018"`, or let Android Studio prompt for
  it.
- The Unicode mapping tables `mruby-lcf`/`mruby-rgss`'s code generators need
  at build time, same as every other target — see the root
  [`README.md`](../../README.md#build-natively-without-nix)'s "Build natively
  without Nix" section, or just run under the nix devShell, which supplies
  them automatically.
- `gperf` and `bison` on `PATH` (regenerate mruby-compiler's lexer/grammar if
  a patch under `patches/` touches them; normally a no-op since the checked-in
  generated files are already newer).

```sh
export cp932_table=/abs/path/to/bestfit932.txt   # see the root README section above
export jis0208_table=/abs/path/to/JIS0208.TXT
cd app/android
./gradlew :app:assembleDebug     # -> app/build/outputs/apk/debug/app-debug.apk
```

Install it with `adb install app/build/outputs/apk/debug/app-debug.apk`, then
push an RPG Maker 2000/2003, XP, or VX/VX Ace project's files to this app's
external-files directory — the Android equivalent of the PSP port's fixed
Memory Stick path (ADR 10):

```sh
adb push /path/to/game/. /sdcard/Android/data/org.rpg2k.android/files/game/
```

`RpgMakerCloneActivity`
(`app/src/main/java/org/rpg2k/android/RpgMakerCloneActivity.java`) points
`--game_dir` at exactly that directory. There is no in-app project picker —
one APK install is one game, matching the PSP port's own "one EBOOT, one
game" scope for this first slice.

## Not yet wired (later slices)

- **Running on a real device or emulator.** See Status above.
- **RPG Maker MV/MZ (the WebGL/quickjs-ng maker).** `mruby-mvjs/src/mvgl.cxx`
  compiles to its inert-stub fallback on Android — its desktop/Mesa-oriented
  EGL surfaceless path calls a symbol (`eglGetPlatformDisplay`) Android's
  `libEGL.so` does not export. RPG2000/2003, XP and VX/VX Ace are unaffected.
  See the ADR's Decision section.
- **On-screen touch controls.** The wasm build's on-screen keypad
  (`src/shell.html`) has no Android equivalent yet; a physical
  keyboard/gamepad is the only input path SDL2's Android backend wires up on
  its own.
- **An in-app project picker/importer.** `adb push` to a fixed path is the
  only way to get a game onto the device right now (see Building above).
- **More than one ABI.** Bring-up scope is `arm64-v8a` only
  (`app/build.gradle`'s `abiFilters`). See the ADR's Decision section for what
  widening this needs.
- **Signing/release packaging, a Play Store listing, ProGuard/R8 rules beyond
  the stock template.** `proguard-rules.pro` is currently empty;
  `buildTypes.release` exists but has not been exercised.
