- **Wio Terminal**: the compiled Ruby reads the one `mrb_state` from a global
  instead of passing it to every call between compiled functions, which makes
  the firmware smaller. `BC2CPP_IMPLICIT_STATE=0` turns it off.
