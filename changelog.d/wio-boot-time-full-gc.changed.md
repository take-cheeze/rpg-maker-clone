- **Wio Terminal: force a full GC pass right after boot-time class/method
  loading, before the main loop starts** -- reclaims scaffolding objects
  `mrb_load_irep` allocates while registering every gem's classes/methods,
  rather than leaving them for the VM's own lazy GC threshold to catch
  sometime during play. Zero flash cost (a real relink confirms the
  overflow is unchanged). See ADR 116, which also covers why "omit unused
  Ruby methods" doesn't have a safe answer yet -- `mruby-rpg2k` dispatches
  by data-derived symbol (`receiver.send(name)`) in enough places that
  static analysis can't prove a method dead.
