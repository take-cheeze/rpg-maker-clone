- `tools/optcarrot_probe/README.md` records the clean-machine
  re-measurement of `BC2CPP_SELF_REGISTERING` the previous entry left as
  an open caveat: on a genuinely idle box, `iv_bsearch_idx`'s call count
  is confirmed identical (not machine noise) between the change enabled
  and disabled, but the bc2cpp run is a reproducible 6.2% faster anyway
  (287.99s -> 270.14s), traced to a 16.1% drop in packed-symbol-table
  decode calls (`sym_check`/`mrb_packed_int_decode`/`symtbl_get_ptr`/
  `symtbl_is_literal`), plausibly from 3 newly-synthesized struct-aware
  accessor methods bypassing ordinary `SEND` dispatch. No code changed;
  this closes out the "wall-clock impact not established" caveat #1870's
  own description raised, with real numbers instead of a guess.
