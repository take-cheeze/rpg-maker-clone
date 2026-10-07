- bc2cpp: the shared index helpers `bc2cpp_getidx`, `bc2cpp_getidx0` and `bc2cpp_setidx` (`[]` / `[]=`, ADR 0365) no longer end
  in a by-name call in a closed world where only Array, Hash, String, Struct, Proc, Table, class objects (`Array[]`,
  `Hash[]`, a `Struct.new` class's `[]`) and the program's own classes answer: the else arm is a class-tag switch over
  mruby's own bodies and a proven NoMethodError. The new `patches/mruby-expose-index-bodies.patch` (applied by the cmake
  chain, `maix_mruby_build.bash` and `wio_bc2cpp_measure.bash`) exports those bodies as functions that take their
  arguments (`mrb_ary_aget1_impl`, `mrb_struct_aset_impl`, `mrb_proc_aref_impl`, ...) and routes the methods through them
  unchanged. `CallFacts::Answers` now also scans class-level native registrations, so a Class object is a member of `[]`.
  `BC2CPP_INDEX_HELPER_CLOSED=0` keeps the by-name helpers. Covered by the new `scripts/bc2cpp_index_closed_check.rb`
  (each helper against the real method at `mrb_int` 64, 32 and without bigint).
