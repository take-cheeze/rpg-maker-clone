- `tools/bc2cpp/bc2cpp.rb` no longer compiles a literal `Fiber.new { ... }`/
  `Fiber.new do ... end` block through its generic `BLOCK_FALLBACK` path.
  That path wraps every block body as a cfunc-backed `RProc`
  (`mrb_proc_new_cfunc_with_env`), which is safe for `each`/`map`/`sub`/...
  but not for `Fiber.new`: mruby's own `Fiber#initialize`
  (`mrbgems/mruby-fiber/src/fiber.c`) explicitly rejects a cfunc-backed
  proc with `FiberError: tried to create Fiber from C defined method`,
  since its resume/yield machinery works by saving/restoring a bytecode
  program counter into the proc's own irep -- a cfunc-backed proc has
  none. `Fiber.new { block }` call sites are now recognized (a bare
  `GETCONST ... Fiber` feeding an explicit-receiver `SENDB :new`) and
  refused as a `BLOCK_FALLBACK` region, so the containing method instead
  gets the pre-existing, honest `#error unhandled opcode BLOCK` marker and
  falls back to interpreted under `SKIP_UNSUPPORTED=1`, exactly like any
  other genuinely unsupported construct -- rather than compiling to code
  that raises the instant the fiber is first resumed. Verified against
  `tools/optcarrot_probe`'s real `Optcarrot::PPU#run` (the one real
  `Fiber.new` call site in this whole closed world): with
  `BC2CPP_SELF_REGISTERING=1`, exactly that one method (and only that
  one) now falls back, all 15 `scripts/bc2cpp_*_check.rb` static checks
  still pass, and the real project's own 3 compiled gems are unaffected
  (no `Fiber.new` call site exists in their `mrblib` today, confirmed by
  grep -- this is a defensive fix with no observable effect there yet).
  `tools/optcarrot_probe/compiled_run.rb` still excludes `Optcarrot::PPU`
  from `ONLY_OWNERS`: this fix alone is not sufficient to re-enable it, a
  second, deeper issue (compiled code now reachable from the fiber's own
  body before it hits `Fiber.yield` corrupts mruby's fiber resume
  bookkeeping) remains open and is documented in
  `tools/optcarrot_probe/README.md`.
