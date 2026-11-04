- **bc2cpp**: the compiled class-body units are no longer called from `gem_init` by default. The VM already runs each
  class body, so the compiled call was a second run. `BC2CPP_CLASS_BODY_EMIT=1` turns the emission back on.
