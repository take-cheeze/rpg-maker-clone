# 253. bc2cpp closed world: an outside file touches a class only if it can create, reopen, subclass or rebind it

Date: 2026-09-29

## Status

Accepted

## Context

ADR 0210's closed world calls a class opaque (`ClosedWorld#opaque?`) when its
subclasses and instances cannot be enumerated, and a name defined on an opaque
class always keeps a catch-all dynamic dispatch (refusal `:opaque_definer`: 301
sites in the shipped wio build). Besides the boot classes, the reason for most
of them was `touched_outside`: an outside file (native C/C++ from
`scan_native`, foreign Ruby from `scan_outside_ruby`) *spelled* both the root
segment and the simple name of the class. A mention is far too coarse.
`BC2CPP_TOUCH_REPORT=1` (new) lists, per opaque class, the files that touch it
and the construct responsible. On the wio build the touches were:

| class | touching outside file | what the file actually does |
| --- | --- | --- |
| `RGSS::Bitmap Font Plane RGSSError Sprite Tilemap Timeout Viewport Window` | `mruby-rgss/src/lib.cxx` | defines `RGSS::X < Object` natively (the origin of the class the closed world reopens), instantiates and looks up classes, `mrb_const_set`s `_zobjs`/`_display`/`_game_start` |
| `RPG2k` | `app/wio/src/maix_game_main.cxx` | `mrb_obj_new(mrb_class_get("RPG2k"))`, three `mrb_const_set`s on Object |
| `Array` | `3rd/mruby/mrblib/array.rb`, `mruby-array-ext/mrblib/array.rb`, `mruby-enum-ext/mrblib/enum.rb` | `class Array` (a real reopen) |
| `StringIO` | `mruby-stringio/mrblib/stringio.rb`, `mruby-stringio/src/stringio.c` | `class StringIO` (a real reopen), a native subclass through a variable |
| `Object` | boot class | not a touch |

The other classes the task listed as `touched_outside` in other builds (Ruby
gems that mention `RPG2k`) do not exist in the closed-world builds, whose gem
list is checked.

## Decision

`tools/bc2cpp/touch_scan.rb` classifies each outside file instead of spelling
it. A scan returns three things: `hard` (constants the file may reopen,
subclass or rebind), `origin` (constants the file natively defines) and
`legacy` (some construct was unclassifiable). `ClosedWorld` keeps one `Touch`
per file and set; `WILD` in a set stands for an outer namespace the scan could
not resolve and satisfies any root-segment requirement.

- **Ruby files**: `class PATH [< SUPER]`, `class << PATH`, `module PATH`, a
  constant assignment (`X = ...`, `A::X ||= ...`, and every constant on that
  line, since the right-hand side may alias a class), an `include/extend/prepend`
  line, `def PATH.name` and `PATH.dup/clone` put the constants they name into
  `hard`. Any explicit-receiver reopener (`.class_eval`, `.define_method`,
  `.const_set`, `.include`, `.send`, `.singleton_class`, ..., `eval`,
  `Class.new`), a non-constant superclass, `class << expr`, `def var.name`
  or `def (expr).name` makes the file `legacy`.
- **Native files**: `mrb_define_class*` / `mrb_define_module*` record the
  defined name in `origin`, and its superclass argument in `hard` (subclassing).
  `mrb_class_new`, `mrb_include_module`, `mrb_prepend_module`,
  `mrb_extend_object`, `mrb_singleton_class*` put their class operand into
  `hard`. `mrb_const_set/_remove`, `mrb_define_const*`,
  `mrb_define_global_const*` put the written name and the target namespace into
  `hard` (a rebind). `mrb_obj_new`, `mrb_instance_new` and `funcall(:new)` only
  instantiate: they are no touch unless the class operand is unresolvable or is
  `Class/Module/Struct/Data` (which could take a superclass), in which case the
  file is `legacy`, as are a funcall of `send/include/extend/prepend`, a
  non-literal method name, an allocation of a class-like object and a direct
  `->super =` write. Class operands are resolved through `mrb_class_get*`,
  `mrb_module_get*`, `mrb_obj_value`, `->object_class` and built-in handles
  (`E_STANDARD_ERROR`, `mrb->eFoo_class`, matched by normalized name against the
  classes the closed world declares); a variable or call result is unresolved.
  A `mrb_sym` local whose every declaration initialises it with the same
  literal is a literal.
- **Fallback**: a `legacy` file keeps the pre-0253 rule, "every constant the
  file spells" (native files gated, as before, on defining classes or constants
  at all), so an unclassifiable construct can never remove a touch.
- **`opaque?`** consults `hard` and the legacy sets. `origin` sets are ignored
  for a class the closed world declares (its `class_decls` key): defining a
  class natively is where that class comes from, and mruby raises on a
  superclass mismatch with the closed-world declaration. `stable_class_constant?`
  (module and native-only constants, not in `class_decls`) still counts `origin`
  as a touch.

## Soundness argument

A class `C` is non-opaque only if nothing outside the closed world can add a
class to `descendants(C)`, reopen `C` in a way the registry misses, or rebind
`C`'s constant. Outside code can only do that by

1. a `class`/`module` statement, or a constant assignment, naming `C`'s path
   (Ruby) - covered by `hard`; the path check needs the root and the simple name
   in one file's set, and a lexically nested `class Sprite` inside `module RGSS`
   contributes both;
2. reaching `C` by another root (`include RGSS` then an unqualified
   `class Kid < Sprite`, or `Alias = RGSS; class Kid < Alias::Sprite`) -
   covered because `include/extend/prepend` lines and every constant on an
   assignment line contribute their constants;
3. a call on a class *value*: `class_eval`, `define_method`, `const_set`,
   `include`, `send`, `singleton_class`, `Class.new(C)`, `eval` - the receiver
   may be a variable, so the whole file falls back to `legacy` (Ruby), or the
   call's class operand must resolve literally (native);
4. the native API surface that subclasses, mixes in, rebinds or makes classes
   (`mrb_define_class*` with a superclass, `mrb_class_new`, `mrb_include_module`,
   `mrb_const_set`, `mrb_obj_new(Class, ...)`, `funcall(:new)` on a factory):
   each is either resolved to constants that enter `hard`, or the file is
   `legacy`.

By-name method installation (`mrb_define_method`, `def` in a reopen) is not a
touch: those names are already in `outside_names` / `outside_ruby_names`, which
`refusal` checks before any class question (`:core_or_native`), so a guard
chain never turns a fallback into `bc2cpp_nomethod` for a name outside code can
answer.

**Residual assumption.** A copy of a class object (`Class#dup`/`clone`) is a
class the registry cannot see. `scan_closed_world` already does not model it for
the closed world's own Ruby, so the analysis assumes class objects of declared
classes are not copied. 0253 keeps that assumption where a receiver is not
spelled as a class: `X.dup` and `mrb_obj_value(klass)` copies are touches, but
`mrb_funcall(M, value, "dup")` on a plain value variable (the one such call,
`Bitmap#initialize_copy` copying its `@font`) is treated as an instance copy.
Changing `native_copy` to give up on every unresolved receiver removes the
assumption at the price of keeping the nine `RGSS` classes opaque.

Where a scan cannot classify (variable superclass, unresolved `mrb_obj_new`
class, reopener calls) the file stays a touch exactly as before, so soundness
never depends on a new pattern being complete for the files it does not
understand; it depends on the recognised constructs being the only way a
*classified* file shapes a class.

## Consequences

Measured on the shipped wio closed world (all three compiled gems):

- `opaque_definer` kept sites: 301 -> 2 (the two remaining are `Array` and
  `StringIO`, both really reopened by `class Array` / `class StringIO` in core
  and gem mrblib);
- dead fallbacks (`bc2cpp_nomethod` sites, hot-only and full): 4013 -> 4254
  markers in the generated output, `NOMETHOD_REVIEWED` 2926 -> 3002 keys
  (76 new). They are `db`, `font`, `contents`, `windowskin`, `bitmap`,
  `map_tree`, `title`, `pop_to_map`, `load_map`, ... whose definers `RPG2k`,
  `RGSS::Bitmap/Window/Sprite` were opaque. A sample was read against the Ruby
  source (`Scene::Base#db_system_se -> db`, `Game::Party#to_h -> title`,
  `Scene::Title#update -> start_new_game`, `Scene::MapViewer#save_to_disk ->
  map_path`, `Scene::SkillMenu#apply_switch_skill -> pop_to_map`): the receivers
  are `self` in a `Scene::Base` subclass, an `Actor`, or the game object
  (`parent`/`@parent`), the chain lists exactly the classes that answer the name
  (`RPG2k`, `Scene::Base` and its subclasses, `Game::Actor`), and any other
  receiver would raise the same `NoMethodError` the dynamic send did;
- direct-dispatch sites (`bc2cpp_send` plus `mrb_funcall_with_block`, coverage
  report): 11044 -> 10787; `RPG2k` and `RGSS::Bitmap/Window` get
  `CLOSED_WORLD_SELF`, stable-class-constant and direct construct paths.

Every generated-output difference against the previous build is a removed
dynamic send or guard/`MONO_EMBED_GUARD` comment replaced by a guarded direct
call, `CLOSED_WORLD_SELF`, a `bc2cpp_nomethod` terminal, a direct
`bc2cpp_direct_alloc` construct, or a stable-class constant cache.

Fixtures in `scripts/bc2cpp_closed_world_check.rb` cover a Ruby file that only
mentions a class (not opaque), reopens, subclasses, rebinds, aliases, copies or
`class_eval`s it (opaque), a namespace collision (not opaque), and native
files that define-only or instantiate (not opaque) versus subclass, `class_new`,
`const_set`, `include_module`, or use an unresolvable class operand (opaque).
