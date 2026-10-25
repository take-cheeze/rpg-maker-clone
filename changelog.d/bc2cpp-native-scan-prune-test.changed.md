- **bc2cpp** native scans no longer read the mrbgem `test/` helpers
  (`ProcExtTest`, `DirTest`, `binding_in_c`, `instance_exec_from_c` on
  `Kernel`): mruby compiles only each gem's `src/` into `libmruby.a`, so
  those names are phantom definers that could only flip MONO to POLY or
  defeat a proof. `core_native_srcs` drops them; cold scan fills hash and
  read fewer files.
