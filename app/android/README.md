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

## Status: runs on a real device

This produces a real, installable debug APK (verified with `aapt dump
badging` and `unzip -l`) that packages `libSDL2.so`, `libSDL2_mixer.so` and
`librpg_maker_clone.so` (mruby, LVGL, gflags, ng-log, uni-algo and
quickjs-ng all linked statically into the latter). It has been built,
installed and run on a real device (`C330`, `arm64-v8a`): Nepheshel (the
RPG2000 test bed) boots to its title screen, renders through LVGL's software
rasteriser over SDL's window-texture path, and plays — title menu, opening
demo choice and map walking — with the touch controls described below.

Three on-device findings shaped the code since the first bring-up commit:

- **`SDL_HINT_FRAMEBUFFER_ACCELERATION=0` killed the only window-framebuffer
  path Android has.** The #449 desktop workaround is now skipped under
  `__ANDROID__` (same reason it is already skipped for macOS/Cocoa).
- **`Dir` was missing from the cross-built mruby.** mruby 4.0 moved it out of
  `mruby-io` into its own core gem; the game binary only had it by accident
  via a test-suite dependency leak that does not exist in cross builds.
  `build_config.rb` declares `mruby-dir` explicitly now.
- **Native stderr was invisible.** SDL's Android activity never redirects it
  to logcat, so ng-log output and error reports vanished. `main.cxx` bridges
  fd 2 into logcat under the `RPG2K` tag as its first action.

See ADR 58's Consequences for the full list of what remains
bring-up-scope-only (MV/MZ rendering, one ABI, no project picker).

## Touch controls

With no keyboard or gamepad attached, the window itself is the controller:
touch positions map onto RGSS keys by zone. The left 40% of the window is a
*floating* D-pad — drag from wherever the thumb lands; direction comes from
the offset against the touch-down anchor (dead zone ~4% of the window edge),
and diagonals work. The right side splits into **B / cancel** (upper) and
**C / confirm-A** (lower) at half height; the middle band is dead space so a
resting thumb triggers nothing. Each finger keeps its own role, so steering
with one thumb while tapping menus with the other works. Implementation:
`src/sdl_input.cxx` (SDL finger events → the same RGSS::Input buffer the
keyboard watch feeds).

The zones are also **drawn**: `src/android_vpad_ui.cxx` renders a D-pad cross
bottom-left and B/C circles on the right on LVGL's top layer, translucent over
the scene, highlighting whichever control is held. The widgets have no click
handlers — they only show where the zones are; input still comes from the zone
logic above, so a thumb anywhere in a left-side zone steers.

## Centred picture and FPS counter

A phone window is not 4:3. The SDL surface resizes LVGL's display to
window/zoom, and mruby-rgss hangs every game object off a single *game root*
container; the shell centres that root in the display (`src/android_vpad_ui.cxx`)
so the game picture sits mid-screen with letterbox on all sides, and the pad's
corners land in the black bands. An FPS/CPU readout (LVGL's perf monitor,
Android-only in `include/lv_conf.h`) shows in the top-right corner.

## Launcher icon

The launcher uses the project's Sapphire Chip mark (`assets/logo/`), scaled
into each `mipmap-*` density — not SDL's default asset.

## Building

With nix, everything the build needs — the SDK (platform 34, build-tools),
NDK 27.2.12479018, CMake 3.22.1, a JDK, the Unicode mapping tables and the
mruby lexer tools — comes from the flake's `android` devShell, the same way
`psp` carries the PSP toolchain (`packages.android-sdk` in `flake.nix`):

```sh
nix develop .#android -c bash -c 'cd app/android && ./gradlew :app:assembleDebug'
# -> app/build/outputs/apk/debug/app-debug.apk
```

Without nix, the manual recipe:

- An Android SDK with API 34 platform + build-tools installed
  (`ANDROID_HOME`).
- NDK 27.2.12479018 (`app/build.gradle`'s `ndkVersion`) — installable via
  `sdkmanager --install "ndk;27.2.12479018"`, or let Android Studio prompt for
  it.
- A JDK (17+; CI uses Temurin 21) for Gradle.
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
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"   # if not on PATH
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

- **RPG Maker MV/MZ (the WebGL/quickjs-ng maker).** `mruby-mvjs/src/mvgl.cxx`
  compiles to its inert-stub fallback on Android — its desktop/Mesa-oriented
  EGL surfaceless path calls a symbol (`eglGetPlatformDisplay`) Android's
  `libEGL.so` does not export. RPG2000/2003, XP and VX/VX Ace are unaffected.
  See the ADR's Decision section.
- **An in-app project picker/importer.** `adb push` to a fixed path is the
  only way to get a game onto the device right now (see Building above).
- **More than one ABI.** Bring-up scope is `arm64-v8a` only
  (`app/build.gradle`'s `abiFilters`). See the ADR's Decision section for what
  widening this needs.
- **Signing/release packaging, a Play Store listing, ProGuard/R8 rules beyond
  the stock template.** `proguard-rules.pro` is currently empty;
  `buildTypes.release` exists but has not been exercised.

## Debugging on-device

Native stderr reaches logcat under the `RPG2K` tag (see Status above), so:

```sh
adb logcat -c && adb shell am start -n org.rpg2k.android/.RpgMakerCloneActivity
adb logcat -d -s RPG2K        # engine logs + full error reports
adb logcat -d | grep -E 'F libc|F DEBUG'   # native aborts / tombstone headers
```

Known issue: quitting the game from its title menu leaves the `SDLActivity`
process alive in the background, and relaunching into that process fails a
second time around — gflags rejects the activity's `--game_dir` argument
("unknown command line flag") and the run dies. `adb shell am force-stop
org.rpg2k.android` (or swiping the app out of recents) clears it; a proper fix
wants the activity to exit its process on game quit.
