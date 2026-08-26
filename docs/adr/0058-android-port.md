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

**Update (2026-08-25): the present path was tuned for frame rate.** The
on-device perf monitor showed 22fps on the title screen with ~63ms of the
~64ms frame spent in LVGL's flush — not in the game. Three fixes, each
measured on the C330:

- **The SDL renderer is now accelerated on Android** (`LV_SDL_ACCELERATED 1`
  under `__ANDROID__` in `include/lv_conf.h`; desktop/wasm keep 0). The
  software renderer's only Android present path is `SDL_CreateWindowTexture`
  (this ADR's own finding above), and it CPU-stretches the framebuffer to the
  full window and copies the surface again on every present. The GPU renderer
  — what every other SDL2 Android app uses — uploads the game-sized texture
  and stretches on the way out: flush fell 63ms → ~5ms, and a doubled,
  mirrored picture the software path produced on this device went with it.
  `src/main.cxx` skips its `SDL_HINT_RENDER_DRIVER=software` hint under
  `__ANDROID__` so the accelerated request is not steered back.
- **`LV_DEF_REFR_PERIOD` is 16ms on Android** (stock 33ms elsewhere): the
  refresh timer is what actually presents, so 33ms capped the picture at
  ~25fps whatever the frame cost.
- **The display zoom fits the game's height** (`fit_zoom_to_game` in
  `src/android_vpad_ui.cxx`): the static zoom-2 layout rendered LVGL at
  window/2 = 599x339 — 2.8x the game's pixels — for the GPU to stretch again.
  Fitting the zoom to the game height renders the picture 1:1 and halves the
  software-raster and upload cost in map scenes; the pad now overlaps the
  picture's translucent edges instead of the letterbox bands.

Title screen 22 → 60fps; map/intro scenes roughly 2x, now bounded by mruby
game-logic speed on this low-end CPU rather than by the present path.

**Update (2026-08-25, later): the map scene stopped redrawing identical
pixels.** With the present path fast, on-device profiling showed the frame
still going to work whose output did not change: the tile-layer buffers were
recomposed every frame (~19ms), the picture layer cleared its full-screen
bitmap every frame with no pictures (~7ms), the panorama re-tiled with
per-pixel blend blits (~49ms a walking frame), and per-frame
`opacity=`/`x=`/`y=` pokes of *unchanged* values invalidated full-screen
sprites — LVGL's local-style setter refreshes without comparing (~13ms of
whole-display re-render). Fixes, all in `Scene::Map` (mruby-rpg2k) plus
value guards in the native sprite setters (mruby-rgss): the layer
composition, picture layer and panorama now keep last frame's pixels when
nothing they show moved; the tile-animation step re-blits only the cells
that follow it; the panorama memcpy-copies instead of blending; the native
`opacity=`/`x=`/`y=`/`visible=` setters skip the style set on an equal
value. Measured: intro map 14 → 40-45fps, overworld 26fps standing, battle
53-59fps, `gfx.lvgl` 22 → ~2.5ms on a static frame. The floor is now mruby
game logic on the device's CPU; the C-side quad batching follow-up has since
landed (`Bitmap#blt_quads`, one native dispatch for a whole tile's quads:
animation-step `map.layers` spikes ~57-86 → 30-54ms, and event-page
re-selection now skips events whose condition inputs did not change,
`map.refresh_pages` 5.5 → 0.9ms on the town map); what remains is the
per-pixel compose cost itself (a row-copy fast path for opaque chipset
pixels) and the scrolling present path.

**Update (2026-08-26): the per-pixel compose cost got its row-copy fast
path** — the first of those two remainders. `blt_pixels`, the loop `#blt`
and `#blt_quads` share (`mruby-rgss/src/lib.cxx`), re-derived the pixel size
and re-checked both bitmaps' bounds for *every* source pixel, even where the
old opaque-source branch then overwrote the pixel wholesale — and chipset
tiles are nothing but opaque rows. Now the rect is clipped once up front
(the same carry-along clip `bmp_copy_blt` already used), and when both
bitmaps share a format and the opacity is full, any row whose every alpha
byte is 255 goes down as one `memcpy`; rows with any transparency keep the
pixel loop, now bounds-check-free because of the pre-clip. The picture is
unchanged by construction — a fully-opaque row's memcpy writes exactly what
the per-pixel overwrite branch wrote — and the mruby-rgss blt parity tests
plus `scripts/rpg2k_render_check.rb`'s 41 frame checks confirm it. Measured
on the host with a 336-tile full-grid rebuild through `#blt_quads`
(21x16 chips, the exact shape of `rebuild_tile_cache`): ~0.6ms → ~0.02ms a
pass (~30x); charset-shaped blits (transparent margins around an opaque
core) dropped ~4x from the hoisted clipping alone; blended blts are
unchanged, as they must be — they never had an overwrite path to shortcut.
The animation-step `map.layers` spikes above were precisely this loop, so
the device-side win should track whatever share of them was compose rather
than dispatch; the scrolling present path is the one named remainder left.

**Update (2026-08-26, later): CI now boots the APK itself, on an emulator.**
Every update above was confirmed by hand on the `C330`; nothing in CI ever ran
the APK past `aapt dump badging` (the `android` job's own scope). The new
`android-smoke` job (`.github/workflows/build.yml`, `needs: android`) closes
that specific gap: an x86_64 `google_apis` emulator under KVM, leaning on the
Android Emulator's own ARM-binary translation (bundled with Google APIs
images from API 28 on — this app's own `minSdk` floor, not a coincidence) to
run the arm64-v8a `.so` unmodified rather than needing a second native build.
It installs the APK, stages Nepheshel into the app's own internal storage
(scoped storage on this AVD image blocks every other route — see
`scripts/android_smoke_check.bash`'s own comments), launches
`RpgMakerCloneActivity` with a CI-only `rpg2k_extra_args` intent-extra hook
(`getArguments()`, absent on every real launch) carrying the same
`--test_play --rpg2k_new_game --timeout_ms=...` flags
`scripts/rpg2k_boot_check.bash` already uses on desktop, and asserts the
engine reaches `[RPG2k-MAP]` with no native crash marker in the device log.
This is a *boot-and-crash* check, not a performance measurement — an
emulator's frame times mean nothing next to the C330 numbers above, which
`docs/android-perf-followups.md` still asks a real device for — but it does
catch the class of bug every update above found by hand before a device was
available: a runtime crash, a missing lookup, a native abort that only shows
up once the `.so` actually loads and runs. `continue-on-error: true` for now,
the same starting point `psp-smoke-game` used before it proved stable.

**Update (2026-08-26, still later): the new job's first clean run found a
real crash — cause not yet pinned down.** Once the storage plumbing above
worked, `android-smoke` reached `[RPG2k-MAP]` — the engine really does
boot, load Nepheshel and put up the map on this emulator — and then the
process itself SIGABRTed about half a second later, on three straight
runs: `Scudo ERROR: invalid chunk state when deallocating address 0x...`
in `SDLThread`. That is Android's hardened allocator (Scudo) catching a
real double-free or heap-corruption-then-free, not an emulator artifact by
itself — Scudo only reports it at the *deallocation* that notices the
damage, which can be well downstream of whatever actually corrupted the
chunk, so the backtrace alone (bionic/Scudo frames, then one unsymbolized
address in our own `.so`) does not say where.
[This engine's own CI logs](https://github.com/take-cheeze/rpg-maker-clone/actions)
cannot be fetched from every environment this port is worked from (an
outbound-network policy blocks the Azure Blob Storage host GitHub Actions
artifacts download from), so a first pass at correlating the crash with
nearby audio-stack log lines (`PlayerBase`/`AudioTrack`) turned out to be
reading the *wrong* run's log entirely — a mistake worth naming so it is
not repeated. `scripts/android_smoke_check.bash` now prints the full
device log for the crashing run's own pid directly into the CI job's own
console on either assertion failure, precisely so this does not require an
artifact download to investigate next time.
Two standing hypotheses, neither confirmed: an actual bug in this engine's
audio path (Glibc's allocator on desktop is far less strict about this
class of corruption than Scudo, which would explain nothing in the desktop
test suite catching it), or an artifact of running an arm64-v8a `.so`
through this AVD's `ndk_translation` binary-translation layer specifically
(present because this is an x86_64 host emulator, not real arm64 hardware
— see the `android-smoke` job's own comment) doing something the real C330
device's native execution never would. Telling them apart needs either a
real device or an arm64-v8a system image run (impractically slow for CI,
per that same comment, but usable as a one-off diagnostic). Root-causing
this is out of scope for the CI-infrastructure change that added
`android-smoke` itself; tracked as a follow-up rather than fixed here.

The 4th run — the same commit as the print-full-log-on-failure fix above,
no engine code touched — came back clean: `[RPG2k-MAP]`, no crash marker,
15 seconds start to finish. Three failures then a clean pass is exactly
the shape of a real race rather than a deterministic bug in dead code, and
rules out "always crashes, just wasn't checked before": it does not always
crash. That cuts against the second hypothesis somewhat (a translation-
layer artifact would more plausibly be either deterministic per input or
never triggered at all) without ruling it out, and means the next
reproduction is itself the open question — `android-smoke` will keep
surfacing it if and when it recurs, now with full pid-scoped context
attached when it does.

**Update (2026-08-26, later still): it recurred, and this time the
pid-scoped context above actually caught it.** `print_pid_context()`'s
fix landed and the crash reappeared a run later; unlike the first three
occurrences (whose nearby-log correlation turned out, per the correction
above, to be reading a different run entirely), this one is genuinely
this crash's own pid, verified against the job's own log. The full
timeline for this run (times trimmed to `HH:MM:SS.mmm`, tids as logged):

```
11:34:44.478  PlayerBase::PlayerBase()             tid 3530 (SDLThread)  -- device opened (rgss_audio_init/Mix_OpenAudio)
11:34:44.551  PlayerBase::stop() from IPlayer       tid 3582              -- AudioTrack stop(15): 0 frames (device-open probe stop)
...
11:35:12.080  [RPG2k-MAP] map=371 x=10 y=7                                -- map scene reached
11:35:12.168  PlayerBase::stop() from IPlayer       tid 3582              -- AudioTrack stop(15): 1218560 frames (title/loading BGM, ~27.6s, stopped)
11:35:12.221  PlayerBase::stop() from IPlayer       tid 3530 (SDLThread)  -- a SECOND stop(), 53ms later, on our own thread
11:35:12.539  scudo: Scudo ERROR: invalid chunk state when deallocating address 0x6ffe3a7265f0
11:35:12.539  F libc: Fatal signal 6 (SIGABRT), tid 3530 (SDLThread)
```

Two `stop()` calls land within 53ms of each other on two *different*
threads: tid 3582, which every occurrence so far shows only ever issuing
`IPlayer` stops (i.e. Android's own OpenSLES/AudioTrack framework thread,
not anything this engine spawns), and tid 3530, which is `SDLThread` --
the thread this engine's own `Mix_HaltMusic()`/`Mix_FreeMusic()` calls
run on, reached via `bgm_play()` (`src/sdl_audio.cxx`) when the map's BGM
replaces the title/loading BGM. The Scudo abort follows the *second*
(engine-side) stop by well under a second, on that same thread.

That shape — the platform's own audio-framework thread and this engine's
BGM-handoff code independently reaching into what is presumably the same
underlying `AudioTrack`/player object within 53ms of each other, then a
heap-corruption abort — reads much more like a race in SDL2's Android
OpenSLES backend's teardown path (freeing/reusing a player object mid-stop
from the framework's own callback thread while `SDLThread` is also
stopping/replacing it) than a bug in this repo's own code:
`src/sdl_audio.cxx`'s `free_music()`/`play_music()` sequence was already
read in full for this investigation and does not touch any raw buffer or
handle SDL_mixer doesn't already own, and `mruby-rgss/src/audio.cxx` is a
thin, SDL-free forwarder with nothing of its own to race. Nothing here
rules out an SDL2-side bug being *triggered* only through this engine's
specific stop/reload sequence, so "not this repo's fault" is a lead, not
a conclusion -- but it does narrow where a fix would have to land if one
is pursued: SDL2's `src/audio/openslES/` backend (pinned submodule
commit noted above), not this engine's own audio glue.

This is still consistent with — and now gives concrete shape to — both
standing hypotheses above: a real SDL2/OpenSLES concurrency bug that
Scudo happens to catch and glibc happens not to, or that same race
existing only because `ndk_translation`'s binary translation perturbs
the timing between these two threads enough to expose it (a race that
narrow could plausibly *not* reproduce on real arm64 hardware at all).
Distinguishing those two still needs a real device or an arm64-v8a
system image, neither available in the environment this port is being
worked from; still tracked as a follow-up, not fixed here.

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
