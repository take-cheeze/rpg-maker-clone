- `tools/bc2cpp/bc2cpp.rb`'s `SEND`/`SSEND` call-site compiler can now
  "unroll" a splat (`n=*`) and/or double-splat (`nk=*`) argument list into
  an ordinary call instead of an unconditional `#error` -- previously the
  second-largest `#error` category (49 occurrences whole-program). Only a
  splatted Array/Hash traced back to a compile-time-fixed-size LITERAL
  (`ARRAY`/`HASH`, MOVE chains followed, the same backward-scan mechanism
  `array_element_source_scan`/`hash_element_source_scan` already use)
  unrolls; a splatted local variable or computed expression still keeps
  the honest `#error` -- this never guesses a register list mrbc's own
  disassembly doesn't give it. New pieces:
  - `splat_array_literal_regs`/`splat_hash_literal_pairs` -- the register-
    list analogues of `array_element_source_scan`'s own `ARRAY` arm and
    `hash_element_source_scan`'s own `HASH` arm, for a call-site argument
    list instead of an ivar's element-class fact.
  - `literal_symbol_write` -- compile_keyword_send's own inline "is this
    register's last write a literal `LOADSYM`" scan, extracted into a
    shared helper (identical question, reused verbatim by
    `splat_hash_literal_pairs`' own double-splat key extraction; a pure
    refactor, verified byte-identical generated output for every existing
    ordinary keyword call site).
  - `compile_keyword_call` -- `compile_keyword_send`'s own MONO-target-
    resolution/keyword-table/arity/direct-`_impl`-call tail, similarly
    extracted so `compile_splat_send` can devirtualize an unrolled
    double-splat/keyword-pair call through the exact same rule (mruby's
    own `mrb_funcall*` family can never carry keywords at all --
    `compile_keyword_send`'s own top comment -- so a keyword-carrying
    unroll has no dynamic-dispatch fallback the way a plain positional
    one does).
  - `compile_splat_send` -- the new entry point: a plain positional-only
    unroll compiles to an ordinary `dynamic_dispatch_line` `mrb_funcall`
    (devirtualizing that further -- MONO/POLY/TYPED -- is a natural
    follow-up once this lands); a keyword-carrying unroll (double-splat,
    or a literal keyword tail riding alongside a positional splat) goes
    through `compile_keyword_call` instead.

  A real, serious bug was caught and fixed before this ever shipped, not
  after: real `OP_ARRAY` codegen (`compile_insn`'s own ARRAY case)
  overwrites its own base register with the constructed Array object --
  that register is also element 0's own source register. Reading it back
  as a plain `r<base>` for the unrolled call's first argument (the first
  version of this change) would have silently passed the freshly-built
  Array object itself as argument 0 instead of the real value. Fixed by
  reading every element back out through `mrb_ary_ref(M, r<base>, k)`
  instead of a raw register for the whole list, not just index 0 -- one
  rule, not an off-by-one special case. Caught by inspecting the actual
  generated call for a real whole-program site
  (`Game::Battle::AllTargetSkillCommand.new(*args)`) before verifying
  further, not by a downstream test failure. The double-splat/keyword
  path was never at risk the same way: it only ever reads VALUE
  registers (never touched by `OP_HASH`'s own equivalent base-register
  overwrite -- that overwrite lands on key 0's register, and keyword
  names are read from the source `LOADSYM` text at compile time, never
  by re-reading a register's runtime value).

  Verified via a real whole-program regen (fresh, correctly-patched host
  `mrbc` -- see this repo's own build-mruby patch set): 5 real call sites
  unrolled (`Game::Battle::AllTargetSkillCommand.new(*args)` twice,
  `Game::Battle#command_skill`/`#command_skill_all` twice more, each a
  `n=N|nk=*` positional-plus-keyword-splat shape), 3 methods move from
  `#error` to compiling clean (`compiled clean` 1969 -> 1972), the splat/
  keyword `#error` count itself drops 49 -> 44, whole-program `#error`
  total 816 -> 811. Inspected the real generated call for every one of
  the 5 unrolled sites directly (not just the aggregate counts) --
  correct argument order and count in each, including the
  `mrb_ary_ref`-based positional-splat fix above. `bash
  scripts/bc2cpp_coverage_check.bash`: fresh. `scripts/
  rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), `scripts/lcf_testbed_check.rb` all still pass (none of
  these touch bc2cpp's own generated output directly, but exercise the
  same mrblib sources it compiles). A full whole-program `g++
  -fsyntax-only` compile of the generated output wasn't reachable in this
  session's own sandbox (no SDL2 devshell); instead, directly compiled a
  minimal `g++ -std=c++17 -fsyntax-only` smoke test reproducing the exact
  new `mrb_ary_ref`/`mrb_funcall` call shape against this repo's own real
  mruby headers (including the generated `presym` table) -- clean.
