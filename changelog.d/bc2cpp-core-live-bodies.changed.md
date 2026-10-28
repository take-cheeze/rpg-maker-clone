- **The core-natives proof reads core Ruby by liveness.** A name a `def` only
  defines no longer counts as a lookup. A core mrblib method body's sends count
  only once its own name can be looked up, or once compiled code calls its
  `_impl` directly. The closed build leaves more unreachable core natives out
  of its method tables as a result. See "Core ROM entries" in
  `docs/bc2cpp-unregistered-methods.md`.
