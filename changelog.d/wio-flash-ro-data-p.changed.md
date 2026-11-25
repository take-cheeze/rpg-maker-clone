- **Wio Terminal**: a String whose bytes are in flash (internal flash or the
  QSPI window) now points at those bytes instead of copying them onto the
  heap. mruby's `mrb_ro_data_p` now knows these addresses on this board.
