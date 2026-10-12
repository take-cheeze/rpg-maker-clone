# 0417. RGSS::Tts exists only in the build that can back it

Date: 2026-10-12

## Status

Accepted

## Context

`RGSS::Tts` is the Zundamon (ずんだもん) message-window narration of ADR 0046. Its native methods
(`mruby-rgss/src/tts.cxx`) forward to a backend table (`include/rgss_tts.hxx`). The only backend is
`src/voicevox_tts.cxx`: VOICEVOX CORE `dlopen()`'d inside the desktop executable that already links SDL_mixer
(`--zundamon_tts`; `RGSS_TTS_HAVE_DLOPEN`, Linux and macOS, never Emscripten). The only Ruby caller is
`Scene::Map#speak_message`.

Which builds can ever install that backend is a short list, because the backend is linked into the root
`CMakeLists.txt` executable and nothing else:

| mruby build | links | backend possible | `RGSS::Tts` after this ADR |
|---|---|---|---|
| `host`, desktop (Linux, macOS) | the `rpg_maker_clone` executable | yes (`--zundamon_tts`) | registered, Ruby call site present |
| `host`, `rake test` (mrbtest) | the standalone test binary | no backend is linked, but the native tests (`mruby-rgss/test/native_direct.rb`) cover `Tts` | registered, as before |
| `host`, bootstrap inside a cross build | only `mrbc` | no | registered (the build is thrown away) |
| `wio` (Wio Terminal; the m5stack and nano7 firmware link this libmruby) | the PlatformIO firmware | no | gone |
| `maix` | the PlatformIO firmware | no | gone |
| `psp` | the EBOOT | no | gone |
| `emscripten` | the wasm page (no `dlopen`) | no | gone |
| `android` | `libmain.so` (`__linux__` is defined, but no VOICEVOX CORE is shipped and the asset directory is a host source path) | no | gone |

Before this ADR every one of the "gone" builds registered three native methods that could only answer "not
available", compiled a Ruby call site, and put `RGSS::Tts` into every bc2cpp closed-world analysis. The class is
native-only, so bc2cpp's constant tables do not know it, and `RGSS::Tts.available?` / `RGSS::Tts.speak` stayed
by-name sends in the generated C++ (`bc2cpp_send(M`). Its native `stop` registration also gave the bare name `stop`
a native definer next to `Interpreter#stop`.

## Decision

`tools/rgss_tts_config.rb` is the one place that says which builds can have a backend (`RgssTtsConfig.backend_possible?`,
true for the mruby build named `host` only). Everything else keys on it:

- **Native.** `mruby-rgss/mrbgem.rake` compiles `tts.cxx` into the `host` build only; every other build compiles
  `mruby-rgss/src/tts_off.cxx` instead, an empty `rgss_tts_define`. `lib.cxx` calls that function unconditionally and
  is deliberately not edited: `tools/bc2cpp/native_class_results.rb` and `native_ivar_scopes.rb` pin its digest, and
  a first attempt that guarded the call with `#ifndef RGSS_NO_TTS` invalidated the audited RGSS facts, turning
  `Bitmap#fill_rect` and other direct calls into by-name sends (+25 `bc2cpp_send(M` in the wio closed world).
  `src/voicevox_tts.cxx` also treats `__ANDROID__` as having no `dlopen` backend, so it no longer refers to
  `rgss_tts_install_backend` in the one executable that links a libmruby without `tts.cxx` (`--zundamon_tts` still
  parses everywhere and logs that the build has no backend).
- **Ruby.** `speak_message` moved out of `scene/map.rb` into `mrblib/scene/map_tts.rb` (the Ruby is unchanged, the
  method is still a private `Scene::Map` method). `mruby-rpg2k/mrbgem.rake` drops that file from the other builds'
  `rbfiles` and appends `mrblib_limited/map_tts_off.rb`, an empty private `speak_message`. This is the repo's usual
  `spec.rbfiles -=` mechanism: no `defined?` test runs in the hot path, and no Ruby in a limited build names
  `RGSS::Tts`. The stand-in is outside `mrblib/` on purpose, so the many scripts that glob `mrblib/**/*.rb`
  (coverage, field audit, the CRuby scene check) see exactly one definition.
- **bc2cpp.** `closed_world_mrblib_srcs(tts:)` picks the same file per build (its default, the canonical wio world,
  is the limited one), `bc2cpp_rgss_native_srcs` and `bc2cpp_closed_world_outside_srcs` leave `tts.cxx` out of
  `NATIVE_SRCS` for the limited builds, and `scripts/bc2cpp/coverage_report.rb` and the nomethod probe use it for
  `wio`. The four `*-compiled/mrbgem.rake` pass the build's name. The canonical, target-independent probes
  (`never_called_registrations.rb`, `wio_registered_methods.rb`) are unchanged: their verdicts hold for the desktop
  world too, because the two worlds differ by one method that calls only natives.

`scripts/tts_limited_check.rb` pins all of it (`ruby-checks` job; `--bc2cpp` in the nightly `fast` shard): per
build name, the real `mrbgem.rake` files give the expected `rbfiles`, objects and defines; no limited build
compiles Ruby that names `Tts`; the bc2cpp source sets agree; `lib.cxx` is unchanged and
the stand-in registers nothing; `speak_message` behaves as the pre-ADR method on a spread of inputs where Tts exists
(including `available?` false and blank text) and is a no-op that never touches `RGSS::Tts` where it does not; and
with `--bc2cpp` the generated C++ of the wio closed world names no `Tts`.

## Consequences

Measured (host `mrbc` without `-g`; arm-none-eabi 14.2.1 from PlatformIO; bc2cpp full mode, i.e. every method, over
the wio closed world for `mruby-rpg2k-compiled`, same commit before and after):

| | before | after |
|---|---|---|
| `bc2cpp_send(M` sites | 1,183 | 1,157 (-26) |
| generated C++ names `Tts` | yes (symbol table, two `POLY_DIAG` lines) | no |
| `Scene::Map#speak_message` compiled | 5 by-name sends | gone (empty method) |
| `tts.cxx` object, Cortex-M4 `-Os` | 252 B text + 12 B bss, 9 symbols | `tts_off.cxx`: 2 B |
| `env:wio_rgss_boot` link, FLASH overflow | 515,704 (image 1,023,608) | 515,496 (image 1,023,400): -208 B |

The 26 is not all `speak_message`: the other 21 are fewer by-name sends in `Interpreter#do_*` and `Scene::Map#perform_*`,
most likely from the native `stop` registration on `RGSS::Tts` no longer sharing a name with `Interpreter#stop` (not
isolated further; each run took about 30 minutes on a loaded machine). In the real, hot-only wio build
`speak_message` is not in `hot_methods.txt`, so only the second effect applies there. Ruby bytecode is roughly
neutral on the limited builds: `map.rb` 176,337 -> 176,143 B plus the 274 B stand-in compiled as its own file (about
+80 B including a second file header); the desktop build is unchanged apart from the file split (404 B file header
included). `wio_rgss_boot` still does not fit the board either way.

Not done, deliberately: the Ruby call sites (`speak_message(plain)` in `open_message`, once in
`append_choice_lines`) stay in `map.rb`, calling the empty stand-in. Removing them would need a per-build rewrite
of `map.rb` that the closed-world analysis would also have to repeat. A new target that links a backend must be
added to `RgssTtsConfig::BACKEND_BUILDS`; the check lists every build name, so a forgotten one is a failure
rather than a silent no-op. Nothing about the desktop feature changed: `src/voicevox_tts.cxx`, the flags, the
assets and `RGSS::Tts` itself are as ADR 0046 left them.
