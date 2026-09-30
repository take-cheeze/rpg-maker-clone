# 0281. bc2cpp calls singleton methods of constants and RGSS natives on proven receivers directly

Date: 2026-09-30

## Status

Accepted

## Context

A ranked analysis of the cached `bc2cpp_send` sites in the wio closed-world report
(`scripts/bc2cpp_coverage_report.rb`, 10,954 sites before this change) found two
receiver-fact gaps:

- **Constant receivers.** 55 sites had `origin=constant_lookup`: `File.exist?`,
  `Math.sin`, `Time.now`, `Marshal.*`, `Graphics.snap_to_bitmap`, `RGSS.mouse_x`
  and `LCF.read_ber`/`write_ber`/`cp932_to_utf8`. Only the Ruby-defined ones
  can reach `CLOSED_WORLD_CONSTANT_OBJECT` (ADR 0259), and three of those did
  not: `LCF.read_ber`/`write_ber` inside `Array1D#initialize`. Their constant
  load follows a `break` in a `begin`/`rescue` loop, which is a `JMPUW`.
  `BytecodeIR#jump_edges_before` read `jump_target`, which is nil for `JMPUW`,
  so it answered "an unresolved jump" and `straight_line_constant_name` gave up
  for every later constant load in that method. Native singleton methods were
  excluded outright as `singleton_owner`, although `RGSS.mouse_x` and friends
  already have frame-independent entry points (ADR 0263).
- **Implicit-self natives.** `_load_error`, `_stbi_error`, `_decoder_ran?`,
  `_init_size` and the `_bgm_*`/`_bgs_*`/`_me_*`/`_se_*` primitives of
  `RGSS::Audio` are sent to `self`, whose class is known (`lexical_self_owner`,
  `lexical_self_singleton_owner`), but ADR 0253's arms guard by class and keep
  the send as their else, so the cached site never went away. The audio and tts
  bindings had no entry point at all: `NativeDirect.class_variables` could not
  attribute `audio`/`tts` (the module is a parameter of `rgss_audio_define`,
  called from another file) and `install_block` only knew `lib.cxx`.

## Decision

1. `jump_edges_before` takes the branch target of every op it is asked for, so a
   `JMPUW` is an edge like any other. The straight-line proof is unchanged: a
   forward edge from before the constant load into the range up to the send still
   bypasses it.
2. `NATIVE_EXACT_DIRECT` (`tools/bc2cpp/codegen_native_exact_direct.rb`): when the
   receiver is proven to be exactly one RGSS class instance, or one class or
   module object, the send calls the `NativeDirect` entry point with no guard on
   the receiver and no dispatch fallback. The receiver proofs are existing ones:
   a stable constant (`constant_object_owner`, so the innermost lexical binding
   wins), or `self` of an exact class / a class or module object's own singleton
   method (`lexical_self_owner`, `ClosedWorld#module_object_self?`).
   The lookup then reaches the native registration when
   - the name is spelled only by the RGSS sources (`native_only_in?`), is
     registered exactly once on the owner (`NativeDirect.registration_count`,
     which returns 0 for any spelling it cannot account for), and no closed-world
     definer, `alias`/`undef`/`define_method` (`symbol_installed_names`),
     `define_singleton_method` or dynamic mixin exists (`ClosedWorld` global
     refusal);
   - no `private`/`public`/`protected`/`private_class_method`/`module_function`
     names it, and none has a non-literal argument
     (`ClosedWorld#native_exact_direct_name_safe?`): the registry tracks
     visibility only for Ruby definitions, and an explicit receiver cannot call a
     private native;
   - the registry holds no Ruby definition of it on the owner (`class << self`
     reopening and `def X.name` are both registry definitions on `X.singleton`)
     and nothing is prepended or mixed in unresolved on the owner or, for a
     singleton, on the class or module itself. An `extend` anywhere is already a
     global refusal, and it would follow the singleton's own table anyway.
   A `:int` argument keeps the guard ADR 0253 uses (`mrb_integer_p`, anything
   else sends), so `mrb_get_args`'s coercion stays on the slow path.
3. `constant_object_send_code` (Ruby-defined singleton methods) now also refuses
   a name some `alias`/`undef`/`define_method` names and any refused closed
   world: an `alias read other` inside `class << Const` gave the name a body the
   registry did not list while the site still called the original directly.
4. The splitter learns the audio and tts bindings (ADR 0263):
   `NativeDirect.cross_file_param_owners` attributes an `RClass*` parameter to the
   module every call site in the sibling sources passes, and `write` anchors the
   generated block before any `rgss_*_define` function, so
   `audio.cxx`/`tts.cxx` get forwarders like `lib.cxx`. The compiler's table
   gains the `RGSS::Audio.singleton` and `RGSS::Tts.singleton` entries.

## Consequences

Measured with `scripts/bc2cpp_coverage_report.rb` (wio closed world, `master` at
6a74f4d2 against this branch):

| | before | after |
| --- | ---: | ---: |
| cached `bc2cpp_send` sites, guarded fallbacks included | 10,954 | 10,934 |
| POLY-marked sites | 1,076 | 1,051 |
| POLY sites with receiver origin `constant_lookup` | 55 | 47 |
| POLY sites with `implicit_self_unresolved` | 339 | 322 |
| `singleton_owner` exclusions | 339 | 333 |
| distinct unresolved generic-dispatch names | 202 | 178 |

The `jump_edges_before` fix alone removes 3 (10,954 to 10,951: `LCF.read_ber` twice,
`LCF.write_ber`). `NATIVE_EXACT_DIRECT` converts 22 sites: `RGSS.mouse_x`/`mouse_y`/
`mouse_pressed?`/`window_title=`, `Bitmap._begin_load`/`_decoder_ran?`/`_load_error`/
`_stbi_error`/`_init_size` and 13 `Audio._bgm_*`/`_bgs_*`/`_me_*`/`_se_stop`/
`_update`/`_midi_available`/`_can_play_mem?` sends. Six of them take an `:int`
argument (`_init_size`, `_bgm_volume`/`_pan`/`_fade`, `_bgs_fade`, `_me_fade`) and
keep one send as the guard's else, so the POLY-marked count falls by 25 and the
cached-send count by 20.

Not converted, with the reason:

- `File.*`, `Math.sin`, `Time.now`, `Marshal.load/dump`: mruby-io, mruby-math,
  mruby-time and mruby-marshal natives whose bodies read the frame
  (`mrb_get_args`, static helpers such as `get_float_arg`, `time_wrap`) and differ
  per platform (`mruby-math-wio`, `hal-wio-io`). They are IO-bound and 30 sites.
- `Graphics.snap_to_bitmap`, `RGSS.to_nfd` (an `#if` in the body),
  `RGSS.__log_bridge_write` (reads `mrb_callinfo`): the splitter refuses them.
- `*_play` (`|` formats): an optional argument count cannot be passed by a
  fixed-arity entry point.
- `_atime`/`_ctime`/`_mtime`, StringIO/IO internals: mruby-io and mruby-stringio
  natives, outside the RGSS split.

Not proven by a run: the entry points need the RGSS gem, which the fixture
harness (`mruby_core`/full-core) does not link. `scripts/bc2cpp_constant_singleton_check.rb`
instead compiles the generated calls against `include/rgss_native_direct.hxx`
(so a wrong signature fails) and compares the Ruby-defined singleton fixtures
interpreted against compiled. The entry points themselves are the ADR 0263 ones,
covered by `mruby-rgss/test/native_direct.rb`.

Observed and left alone: a world with a `define_singleton_method`, `extend`,
`prepend` on a singleton class or other dynamic installer is a global refusal of
`ClosedWorld`, but `CodeGen.stable_class_constants` still let
`CLOSED_WORLD_CONSTANT_OBJECT` resolve the constant, which this ADR now closes
(decision 3).
