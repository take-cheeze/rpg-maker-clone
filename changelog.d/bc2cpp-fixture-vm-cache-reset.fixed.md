- **bc2cpp fixture runtime: each VM starts with clean symbol and constant
  caches.** `Bc2cppFixtureRuntime.run` reset only the owner-class cache between
  the VMs it runs in one process. The symbol and constant-site caches key on the
  `mrb_state` pointer, so a VM opened at the previous one's address read its
  freed constants and symbols (`TypeError: can't convert  into String`,
  `undefined method 'each' for NilClass` on the second VM of an allocation-heavy
  fixture). It now resets them after every `mrb_close`, as each compiled gem's
  `gem_final` does.
