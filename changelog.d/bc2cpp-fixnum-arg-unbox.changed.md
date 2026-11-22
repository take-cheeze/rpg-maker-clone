- **bc2cpp reads a proven Fixnum argument with `mrb_fixnum`.** This covers a
  direct call to a method with a declared Integer parameter and an RGSS
  native's Integer argument. Before, the read was `mrb_as_int` or
  `mrb_integer`, which are out-of-line calls on the Wio's word boxing. The
  Wio firmware is 768 bytes smaller. `BC2CPP_FIXNUM_ARG_UNBOX=0` restores the
  old reads.
