- **bc2cpp**: the closed build drops the `Class#module_function` undefined marker from its method table after init, since
  nothing looks that name up (671 to 670 entries). Undefined markers whose name can be looked up stay.
