# 58. Porting the runtime to Android

Date: 2026-08-22

## Status

Accepted

## Context

ADR 1's goal — run RPG Maker games "on any environment such like embedded
boards" — already has a desktop build, a WebAssembly/browser build (Emscripten),
a Wio Terminal port (ADR 7) and a PlayStation Portable port (ADR 10). Android is
the natural next target: unlike the Wio Terminal and PSP, it needs no bare-metal
toolchain or bespoke HAL work, but unlike the desktop and wasm builds, it has no
system SDL2/SDL2_mixer package and no `main(argc, argv)` a process launcher can
just exec — every native library ships inside an APK, loaded by a Java
`Activity` through JNI.

The runtime's own architecture is already additive-port-friendly for the same
reasons ADR 7 lists: display is LVGL (display-agnostic, injected once through
`rgss_set_display`), input arrives through per-frame poll hooks, and a
non-blocking per-frame host loop is a solved problem (the Emscripten build
already drives one frame per host callback instead of a blocking Ruby `loop
do … end`). What is new for Android is entirely at the *build* and *process
entry* layers, not the runtime itself:

- **No system SDL2/SDL2_mixer.** Every SDL2 Android app vendors the source and
  builds it as part of its own native library — there is no Android system
  linker path an APK's native libs can resolve a system SDL2 against.
- **No `main()` a shell execs.** Android calls into native code through a Java
  `Activity` and JNI. SDL2 already solves this: `SDL_main.h` renames the app's
  `int main(argc, argv)` to `SDL_main`, and `SDL2main` (a small static library,
  `src/main/android/SDL_android_main.c`) is the real JNI entry point Java
  calls, which then calls the renamed `SDL_main` — so `src/main.cxx` needs
  **zero source changes** to become the Android entry point.
- **No NDK cross toolchain in `build_config.rb` yet.** mruby ships its own
  built-in `:android` toolchain (`tasks/toolchains/android.rake`, upstream
  mruby, not something this project carries) that resolves the real NDK clang
  per ABI from `ANDROID_NDK_HOME`/`ANDROID_ARCH`/`sdk_version` — unlike the Wio
  and PSP ports, which hardcode a specific cross-compiler executable name
  because their toolchains have no such self-discovering equivalent.
- **CMake's own Android support is mature enough to reuse the root build.**
  Unlike PSP (a wholly separate CMake project, `app/psp/CMakeLists.txt` —
  pspsdk's toolchain and libc are too different to share) and the Wio Terminal
  (a PlatformIO/Arduino project, not CMake at all), the NDK's own
  `android.toolchain.cmake` is a CMake toolchain file like Emscripten's
  `emcmake` — so Android is a third branch inside the *same* root
  `CMakeLists.txt` next to the existing `EMSCRIPTEN` one, not a fork of it.

## Decision

Add Android as a first-class branch of the existing desktop/wasm build, plus a
Gradle app project that drives it — additive to and independent of every other
target, the same promise the other ports make.

- **`3rd/SDL` and `3rd/SDL_mixer`** are new git submodules (pinned to
  `release-2.32.4` / `release-2.8.1`), vendored source built via
  `add_subdirectory` — the only way to get SDL2 on a platform with no system
  package for it. Both build **shared** (`libSDL2.so`, `libSDL2_mixer.so`):
  `SDL2_mixer`'s own `CMakeLists.txt` links against `SDL2::SDL2` or
  `SDL2::SDL2-static` depending on *its own* `BUILD_SHARED_LIBS`, so the two
  have to agree, and building both shared is what lets Java's `SDLActivity`
  subclass name them as separate libraries to load
  (`SDLActivity.getLibraries()`) rather than needing an `SDL2::SDL2-static`
  target that a shared SDL2 build never defines. Everything else this project
  already links (`lvgl`, `gflags`, `ng-log`, `qjs`, `uni-algo`) still builds
  **static** into the one `librpg_maker_clone.so`, matching the desktop
  build's own choice (`BUILD_STATIC_LIBS`/`BUILD_TESTING` save-and-restore
  pattern) — `BUILD_SHARED_LIBS` is forced back `OFF` immediately after the
  two SDL `add_subdirectory` calls for exactly this reason (see the comment in
  `CMakeLists.txt`; a first pass here left every one of those shared too,
  because `SDL2_mixer`'s own `option(BUILD_SHARED_LIBS ... ON)` is the first
  thing in this build tree to seed that cache variable, and it doesn't let go
  once seeded).
- **`SDL2_mixer`'s codec set is trimmed to OGG Vorbis + MIDI (TiMidity)** —
  the same formats the Emscripten build ships (`SDL2_MIXER_FORMATS=ogg,mid`
  there). Both are bundled directly inside `SDL2_mixer`'s own source tree
  (`src/codecs/{stb_vorbis,timidity}`), so trimming FLAC/MP3/Opus/MOD/WavPack
  keeps the Android build to formats every other target already supports
  instead of pulling in `SDL2_mixer`'s own `external/` submodules (which this
  project does not initialize) for a second, wider codec matrix only Android
  would have.
- **`root CMakeLists.txt` grows a third top-level branch, `elseif(ANDROID)`**,
  next to the existing `if(EMSCRIPTEN)`: it vendors SDL2/SDL2_mixer as above
  instead of `find_package`-ing them, and the executable becomes a `SHARED`
  library (`add_library(${PROJECT_NAME} SHARED ...)` instead of
  `add_executable`) linked against `SDL2main`, `log` and `android` in
  addition to everything the desktop build already links. `install()` and
  every ctest that execs the built binary directly (`mruby_test`, `exe_open`,
  `render_probe`, `audio_probe`, `error_dump`) are skipped for `ANDROID` the
  same way they already are for `EMSCRIPTEN` — Gradle's own build never runs
  `cmake --install`, and none of those tests can exec an ARM `.so` on the
  host running the configure.
- **`build_config.rb` gets an `android` `MRuby::CrossBuild` target**,
  mirroring the `wio`/`psp`/`emscripten` pattern: `MRUBY_TARGET=android`
  builds it, the "host" build alongside it (which only exists to produce the
  natively-executable `mrbc` bytecode compiler) is forced back onto a real
  native compiler via `HOST_CC`/`HOST_CXX` the same way Emscripten's is — and,
  Android-specific, its `CFLAGS`/`CXXFLAGS`/`LDFLAGS` are also reset to
  `gcc.rake`'s plain native defaults instead of inheriting whatever
  `CMAKE_C_FLAGS` the NDK toolchain file seeded (its `-DANDROID` broke that
  *native* mrbc compile outright — see the "Nine minutes to boot" section
  below). The cross target itself uses mruby's own built-in `:android`
  toolchain (`tasks/toolchains/android.rake`) rather than reinventing NDK
  clang path resolution.
- **`mruby-mvjs/src/mvgl.cxx` (the RPG Maker MV/MZ WebGL renderer, ADR 4)
  gains a `!defined(__ANDROID__)` compile-time guard**, alongside its existing
  `!defined(__EMSCRIPTEN__)` one, and falls back to its documented inert-stub
  path there. Android's NDK `<EGL/egl.h>` declares `EGL_VERSION_1_5`, so this
  file's `#if defined(EGL_VERSION_1_5)` branch picks the real
  `eglGetPlatformDisplay` call — but Android's `libEGL.so` does not actually
  export that symbol, which fails at *link* time rather than being caught by
  the header-based `#if`. A real fix needs Android's actual platform-window
  EGL integration (`ANativeWindow`), not this build's desktop/Mesa-oriented
  surfaceless one; MV/MZ was never in this port's first-slice scope, the same
  descoping choice the PSP port already made for the same gem
  (`include_mvjs: false`). LVGL's own OpenGL ES driver
  (`3rd/lvgl/src/drivers/opengles`) still links fine against Android's real
  `libGLESv2.so` — only the desktop-EGL-1.5-specific symbol was ever missing,
  so `GL_LIBS` (EGL + GLESv2) is still discovered and linked for Android, just
  not consumed by `mvgl.cxx` there.
- **`app/android/`** is a new Gradle project (the SDL2 android-project
  template's shape: `settings.gradle`, `app/build.gradle`,
  `AndroidManifest.xml`, one `Activity` subclass) whose `externalNativeBuild`
  points its CMake build **directly at the repo root `CMakeLists.txt`**
  (`app/android/app/build.gradle`'s `path "../../../CMakeLists.txt"`) rather
  than a wrapper — the same file the desktop and wasm builds already use, with
  its own `ANDROID` branches doing the platform-specific work, so there is
  exactly one build description to keep in sync rather than a fork. Java
  glue (`org.libsdl.app.SDLActivity` and friends) is referenced straight from
  the `3rd/SDL` submodule via an extra `sourceSets.main.java.srcDirs` entry
  rather than copied, so an SDL version bump carries its Java side along with
  its native side automatically. `RpgMakerCloneActivity`
  (`org.rpg2k.android`) is a thin `SDLActivity` subclass: it names the three
  libraries this build actually produces
  (`SDL2`/`SDL2_mixer`/`rpg_maker_clone`) and points `--game_dir` at this
  app's own external-files directory — the Android equivalent of the PSP
  port's fixed `ms0:/PSP/GAME/rpg2k` Memory Stick path (ADR 10): `adb push` a
  project's files there and it is what boots. There is no in-app project
  picker, matching the PSP port's own "one EBOOT, one game" scope for this
  first slice.
- **Bring-up scope is one ABI, `arm64-v8a`**, `minSdk 28` (Android 9.0,
  2018) — the lowest API level Android's bionic libc actually implements
  `aligned_alloc(3)`, which LVGL's SDL software-renderer driver
  (`3rd/lvgl/src/drivers/sdl/lv_sdl_sw.c`) calls directly. Confirmed the hard
  way: a `minSdk 24` floor (chosen first, for `std::filesystem` support, which
  only needs API 21+) built everything else — mruby, SDL2, SDL2_mixer — and
  failed only there ("call to undeclared library function 'aligned_alloc'").
  Widening to more ABIs is a matter of widening
  `app/android/app/build.gradle`'s `abiFilters` and the `ANDROID_ARCH` the
  build is configured with per build — mruby's own toolchain already
  parameterizes on it (`MRuby::Toolchain::Android::ARCHITECTURES`); only
  `build_config.rb`'s `conf.host_target` (currently hardcoded to
  `aarch64-linux-android` for onigmo's autotools cross-detection) needs a
  matching case added per new ABI.

### Nine minutes to boot

Three real, non-obvious bugs turned up getting a clean `arm64-v8a` build to
link, in the same "root-cause it, don't route around it" spirit the PSP port's
own nine-bug bring-up trail documents:

1. **`gperf` wasn't installed** in the environment this port was first built
   in, and mruby-compiler's `rake` rule for regenerating
   `mrbgems/mruby-compiler/core/lex.def` from the `keywords` gperf input
   silently produced a 0-byte file rather than failing loudly, corrupting the
   *committed* generated artifact in place (it is checked into the `mruby`
   submodule, not usually regenerated). The resulting build broke with a
   deeply confusing C++ error two layers removed from the real cause
   (`'mrb_reserved_word' was not declared in this scope` — the function
   `lex.def` was supposed to define). Installing `gperf` and restoring the
   file from git fixed it; this is an environment-setup gap the nix devShell
   and CI's own bare-container jobs already close (see
   `.github/workflows/build.yml`'s PSP job, which installs `gperf`/`bison` for
   the identical reason) but a raw non-nix, non-CI shell does not.
2. **The NDK toolchain's own `CMAKE_C_FLAGS` (`-DANDROID`,
   `-D_FORTIFY_SOURCE=2`, ...) leaked into the *native* `mrbc` build.** Root
   `CMakeLists.txt` passes this whole rake invocation's `CFLAGS`/`CXXFLAGS`
   from `CMAKE_C_FLAGS` unconditionally, which is correct for the Android
   *cross* target (mruby's own `:android` toolchain hardcodes its real cross
   flags and never reads `CFLAGS`/`CXXFLAGS` at all, so those are actually
   unused there) but wrong for the "host" build that exists solely to produce
   a natively-executable `mrbc` — `-DANDROID` on that native compile changed
   which branch of `mruby-compiler/core/parse.y`'s generated C++ lexer
   compiled, and it no longer did
   (`'mrb_reserved_word' was not declared in this scope` again, this time for
   real). `build_config.rb`'s `android` branch now resets
   `conf.cc.flags`/`conf.cxx.flags`/`conf.linker.flags` to `gcc.rake`'s own
   plain native-compiler defaults instead of inheriting the cross target's
   flags, the same way `HOST_CC`/`HOST_CXX` already redirect the *compiler*.
3. **`mruby-lcf/cp932_to_unicode.rb` and the Unicode mapping tables it (and
   `mruby-rgss/gen_shinonome_data.rb`) need are not part of this repository.**
   `$cp932_table`/`$jis0208_table` are normally supplied by the nix devShell's
   `fetchurl` derivations (`flake.nix`) or, for a bare non-nix build, by
   downloading and verifying them against the same pinned hashes
   (`scripts/native-build-without-nix.bash` and
   `.github/workflows/build.yml`'s PSP job already do this). A raw shell with
   neither set left `IO.readlines(ENV["cp932_table"], ...)` calling
   `readlines(nil)`, another two-layers-removed failure. Not a bug in this
   port — every target needs this — but worth recording here since it is
   exactly the kind of environment gap that made the two real bugs above
   harder to isolate.

## Consequences

**Update (2026-08-23): the port has since run on a real device** (`C330`,
`arm64-v8a`), and the bullets below were written before that. What changed:

- The window did come up, but died in `CHECK(display)`: Android's video
  backend never implements `CreateWindowFramebuffer`, so
  `SDL_CreateWindowTexture` — which `SDL_HINT_FRAMEBUFFER_ACCELERATION=0`
  switches off — is its *only* window-framebuffer path. The #449 workaround
  is now skipped under `__ANDROID__`, exactly as it already was under
  macOS/Cocoa (`src/main.cxx`).
- Boot then failed in `mrb_open()` with `NameError: uninitialized constant
  Dir`: mruby 4.0 moved `Dir` out of `mruby-io` into its own core gem, and
  nothing declared it for the cross build — the desktop binary only ever had
  it through the host build's `enable_test` leaking `mruby-rgss`'s
  test-suite dependency into the game link. `rpg_maker_gems` now declares
  `mruby-dir` explicitly (`build_config.rb`).
- Native stderr turned out to be invisible (SDL's activity does not redirect
  it), so ng-log output and error reports vanished; diagnosing anything meant
  rebuilding blind. `main.cxx` now bridges fd 2 through logcat (tag `RPG2K`)
  before logging initialises.
- With input confirmed working over injected key events, **on-screen touch
  controls landed**: `src/sdl_input.cxx` maps SDL finger events to RGSS keys
  by window zone (left 40% floating D-pad anchored at the touch-down point,
  upper/lower right split B/C), so a phone plays without attached hardware.
  A real game (Nepheshel, pushed via adb to the external-files directory)
  boots to its title screen and plays.

**Update (2026-08-24): the zones became a visible pad, and the picture
centred.** Invisible zones play but teach nothing, so `src/android_vpad_ui.cxx`
draws the same layout as LVGL widgets on `lv_layer_top()` — D-pad cross
bottom-left, B/C circles right, translucent, highlighting held keys. The
widgets are pure affordance (no click handlers; the zone logic stays the only
input path), and press feedback reaches them through a small queue drained by
an `lv_timer`, because the SDL event watch fires inside `lv_timer_handler`'s
own pump and must not touch LVGL objects re-entrantly. The B circle sits at
40% of display height on purpose: the zone split is window-mid-height, and a
cluster-stacked B would have labelled a button that confirms. Two more
phone-shape consequences landed with it: the game picture is now *centred*
(mruby-rgss hangs every game object off one style-less game-root container
instead of the active screen — `parent_object`/`vp_init`; the shell centres
that root in the letterbox on boot and on `LV_EVENT_RESOLUTION_CHANGED`,
instead of pinning the 4:3 picture top-left above black bands), and LVGL's
perf monitor (FPS/CPU) is on for Android only in `include/lv_conf.h`
(`LV_USE_SYSMON`/`LV_USE_OBSERVER`/`LV_USE_PERF_MONITOR` — the label sits
top-right, clear of the pad). The launcher icon is the project's Sapphire
Chip, replacing SDL's default. One known gap recorded in
`app/android/README.md`: quitting from the title menu leaves the
`SDLActivity` process alive, and a relaunch into it dies on a second gflags
parse — force-stop clears it, and a fix wants the activity to exit its
process on game quit.

The remaining bullets still hold except where quoted above; "no on-screen
touch controls yet" is no longer true.

- Android joins the desktop, wasm, Wio Terminal and PSP builds as a fully
  additive target: none of the CMake/`build_config.rb` changes here touch any
  existing branch's behavior (verified by building each of the three real
  bugs above out one at a time and confirming only the Android configure was
  affected).
- **RPG Maker MV/MZ (the WebGL/quickjs-ng maker) does not render on Android**
  in this first slice — `mvgl.cxx` compiles to its inert-stub fallback there,
  the same gap the PSP port has for the same gem, for a different underlying
  reason (EGL, not "never linked quickjs at all"). RPG2000/2003, XP and
  VX/VX Ace are unaffected — none of them touch `mvgl.cxx`.
- **One ABI (`arm64-v8a`), no Play Store packaging, no signing config, no
  in-app project picker, no on-screen touch controls yet.** This is a bring-up
  slice in the same sense the Wio Terminal and PSP ports' first commits were:
  it proves the whole dependency stack — mruby, LVGL, SDL2/SDL2_mixer, gflags,
  ng-log, uni-algo, quickjs-ng — cross-compiles and links into a real,
  installable APK (`app/android`'s Gradle build produces
  `app/build/outputs/apk/debug/app-debug.apk`, confirmed with `aapt dump
  badging`), not that it has been run on a device or emulator — no Android
  emulator/device was available to boot it on in the environment this port
  was built in. On-screen touch input (mirroring the wasm build's on-screen
  keypad, `src/shell.html`) and an in-app project picker/importer (there is
  currently no way to get a game onto the device except `adb push`ing it to
  `RpgMakerCloneActivity`'s external-files directory by hand) are natural
  follow-ups once real-device behavior is confirmed.
- A second ABI (`armeabi-v7a`, `x86_64`) is additive work along the path this
  ADR already lays out (widen `abiFilters`, add a `conf.host_target` case),
  not a redesign.
