# 0253. Direct RGSS native entry points and native-aware closed-world fallbacks

Date: 2026-09-29

## Status

Accepted

## Context

Sends to RGSS natives (`Window#contents=`, `Sprite#z=`, `Viewport#color=`,
`Rect#x`, ...) stayed dynamic in generated code for two reasons.

- Only a dozen of the ~177 `mrb_define_method` bindings in
  `mruby-rgss/src/lib.cxx` had frame-independent C++ entry points (ADR 0236,
  0242). The rest unpack `mrb_get_args`, which reads the caller's frame, so the
  compiler could not call them without a dispatched frame.
- The closed world (ADR 0210) knew native method *names* only
  (`ClosedWorld#outside_names`), not which class registers them. Every guard
  chain for such a name therefore kept its by-name fallback
  (`CLOSED_WORLD kept: core_or_native`: 1,390 sites in the wio build, led by
  `dispose` 166, `width` 113, `y` 103, `x` 102, `z=` 90, `visible=` 65,
  `contents=` 62, `color=` 59, `windowskin=` 58), even where the program's own
  definers were all listed.

## Decision

Entry points. The setters and getters that the ranked sites call are now
`rgss::<class-or-object>_<name>_direct(M, self, <typed args>)` functions,
declared in `include/rgss_construct.hxx`. Each body lives once: the
`mrb_define_method` binding unpacks `mrb_get_args` and forwards to it, so the
two paths cannot drift, and a disposed receiver raises the same `RGSSError`
from the same `obj_require`. `Rect#x/y/width/height` bindings now call the
existing getter entry points too. The Window, Tilemap and Plane entries (and
the older `window_update_direct`, `tilemap_dispose_direct`,
`window_openness_set_direct`, `window_tone_set_direct`, whose bodies exist only
off wio) get raising link-only stubs under `WIO_TERMINAL`; the classes are
never instantiated there, so their exact-class guards are never true.

Compiler. `tools/bc2cpp/native_direct.rb` holds the declarative
name -> class -> entry point table, with argument kinds. An `:int` argument is
guarded by `mrb_integer_p` and passed as `mrb_int`; on any other value the
arm dispatches, so coercion (Float) and `TypeError` stay with the binding. A
`:bool` argument is `mrb_test`, exactly what `mrb_get_args "b"` does. It also
parses the C registrations (`NativeDirect.registered_owners`) to learn which
classes register a name, and declines a name whose spelling it cannot fully
account for.

`tools/bc2cpp/codegen_native_direct.rb` is prepended to `CodeGen` and wraps
`guarded_fallback_line`: the else of a guard chain gets exact-class arms
(`mrb_obj_class(M, recv) == rgss::native_<class>_class()`) for every table
class that passes `native_wrapper_owner_safe?`'s conditions (native
registration from `mruby-rgss/src`, no Ruby definition on that class, no
prepend). Sites with no guard chain get the same arms in front of their
dispatch. The older zero-argument arms are emitted ahead of the chain as
before; the wrapper only adds what they did not.

Closed world. The by-name refusal for a native-registered name is lifted only
while those arms are in place and all of the following hold:

- every registration of the name comes from `mruby-rgss/src` (provenance is
  recorded per name in `scan_native`; no other native file, no outside Ruby);
- the parser accounts for every registering class, and each has an arm or a
  Ruby definition that replaced its native one (which the chain lists);
- no class in the program, outside Ruby or `Class.new` subclasses one of them
  (`ClosedWorld#native_subclass_free?`), so the exact class names every
  instance.

The final else is then the existing `bc2cpp_nomethod` raise, subject to the
usual `NOMETHOD_REVIEWED` gate. A Ruby-side definer of a class the RGSS natives
create (`RGSS::Sprite`, `RGSS::Window` ... reopened in `mrblib`) no longer
counts as `opaque_definer` because of `lib.cxx` naming it: a `mruby-rgss/src`
file whose every class is defined with an `Object` superclass and whose
constant writes are spelled out cannot subclass, reopen unseen or rebind
(`ClosedWorld#plain_native_source?`); the methods it registers are already
by-name refusals or arms. Only `required_classes` uses this; `opaque?` itself,
and so class-constant stability, is unchanged.

## Consequences

In the wio closed world, `core_or_native` falls from 1,390 to 381 kept sites
and `bc2cpp_nomethod` sites rise from 3,065 to 3,750 (530 new
`NOMETHOD_REVIEWED` keys; each is a defensive branch after a chain that lists
every class that answers). The rest of the converted sites remain dynamic under
a different reason (`unlisted_class`, `singleton_definer`, `opaque_definer`)
that was previously hidden behind `core_or_native`. Hot RGSS setters called with
an unknown or program-typed receiver now reach the native body without
`mrb_funcall`. Adding a native class registration for one of these names
without a table entry silently disables the lift (the parser sees an
unlisted class) rather than miscompiling.

Not converted: names defined by mruby core natives or foreign Ruby (`name`,
`max`, `resume`, `delete`, `include?`, `map`, `string`, `index`, `to_h`, `count`,
`at`, `members`, `shift`, `replace`, `step`, `digits`, `member?`, `chunk`,
`size`, `empty?`), other gems' natives (`stop`, `start`, `flush`) and
variadic natives (`set`); `color` (an extra spelling in `lib.cxx` makes its
class set unproven). Calls whose argument count no native class accepts keep
dispatching so the binding raises `ArgumentError`.
