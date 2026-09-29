- **bc2cpp:** the RData ivar descriptor carries a hash index, so interpreted
  `mrb_iv_get`/`set` on an embedded object no longer scans every slot; this
  was about half of the compiled optcarrot benchmark's run time.
