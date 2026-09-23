- **364 more compiled RPG2000/2003 methods drop their `mrb_define_method`
  registration** (543 in total), -26,712 bytes of `wio_rgss_boot` bc2cpp
  flash in a clean A/B link. Once bc2cpp started embedding ivars into
  more classes, every direct call into such a class went through
  MONO_EMBED_GUARD: an exact-class check, then a by-name `mrb_funcall`
  fallback. The static-dispatch proof (docs/adr/0203) counted that fallback
  as a dynamic lookup. The fallback only runs for a receiver whose class is
  not exactly the owner, and with nothing subclassing the owner, that
  receiver's lookup can never reach the owner's method table. So such a
  fallback no longer counts, provided it is the name's only use and nothing
  subclasses the owner. Subclasses are detected conservatively: closed-world
  superclasses, any written `< Path` or `Class.new(Path)`, any
  `Class.new(expr)`, and native class-defining files. 280 more hand
  `register.cxx` lines go. `scripts/bc2cpp_embed_guard_exemption_check.rb`
  pins each condition. See docs/adr/0206.
