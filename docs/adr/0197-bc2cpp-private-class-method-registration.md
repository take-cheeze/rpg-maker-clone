# 0197. bc2cpp registers private singleton methods; wire RGSS::Audio and RGSS::Graphics

Date: 2026-09-22

## Status

Accepted

## Context

`emit_owner_registrations` (`OWNER_METHOD_REGISTRATION`) installs every
compiled entry point of an owner in `BC2CPP_WIRED_EMBEDDINGS`. mruby has
`mrb_define_method`, `mrb_define_private_method` and
`mrb_define_class_method`, but no `mrb_define_private_class_method`, so a
private singleton method was left unregistered. That kept
`RGSS::Audio.singleton` and `RGSS::Graphics.singleton` off the list. Their
public methods are installed by hand in `mruby-rgss-compiled/src/register.cxx`,
but their private helpers kept running interpreted, and the hand-written list
had also missed the public `Graphics.wait` and `Graphics._transition_map`.
`register.cxx` installed the private `Audio.play_packed` with
`mrb_define_class_method`, which made it public.

## Decision

Emit a `bc2cpp_define_private_class_method` helper when a wired `.singleton`
owner has a private entry. It does what mruby's own `define_method_id` does
(GC arena save, `MRB_METHOD_FROM_FUNC`, `aspec` into the flags, visibility,
`mrb_define_method_raw`), on `mrb_singleton_class_ptr` of the class, with
`MRB_METHOD_PRIVATE_FL`. `mrb_define_method_raw` only forces a singleton-class
method public while its visibility is still the `MT_VDEFAULT` sentinel, so an
explicit private flag is kept. Everything used is public `MRB_API`; the mruby
submodule is not patched.

Add `RGSS::Audio.singleton` and `RGSS::Graphics.singleton` to
`BC2CPP_WIRED_EMBEDDINGS`, and drop the hand `play_packed` registration from
`register.cxx`, which ran after the generated one and would make it public
again. `scripts/bc2cpp_wired_embedding_check.rb` recognises the helper as a
registration call.

## Consequences

The generated RGSS code changes only in registration: the helper, the two
owners' registration blocks, and nine private methods (seven `Audio` helpers,
`play_packed` and `Graphics.brightness_sprite`) plus `Graphics.wait` and
`Graphics._transition_map` that are now installed as compiled code. Module
singletons are not `MRB_TT_DATA`, so no ivar is embedded; the embedding and
devirtualization output is unchanged. `Audio.play_packed` is private again.

Verified:

- The wired-embedding check reports 25/25 and 10/10.
- A harness built against the repo's patched mruby shows an explicit-receiver
  call raising `NoMethodError`, while implicit-`self` calls and `send` still
  work.
- In a real `RPGMAKER_BC2CPP=1` build, `--rgss_effect_probe` and
  `--rgss_audio_probe` pass and an RPG2k New Game boots.

The runtime speedup is not measured.
