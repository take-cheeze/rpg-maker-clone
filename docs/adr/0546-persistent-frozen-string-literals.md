# 0546. Persistent frozen string literals (`# frozen_string_literal: true`)

Date: 2026-10-22

## Status

Proposed

## Context

Ruby code written for CRuby often starts with the magic comment
`# frozen_string_literal: true`. In such a file every plain string literal is a
frozen String: `"abc".frozen?` is true, a mutation raises `FrozenError`, and
equal literals share one object within a VM, so `equal?` holds across calls.

The vendored mruby (pinned in `3rd/mruby`) does not recognise the comment. Its
lexer skips every `#` comment without reading it, so each literal is a fresh,
unfrozen String. The bc2cpp compiler lowers a `STRING` load to
`r<d> = mrb_str_new_cstr(...)` (`tools/bc2cpp/codegen_insn.rb`), which matches
that behaviour, so a magic-comment file cannot be given CRuby's semantics on any
path.

Three constraints shaped the design:

- **Pool entries are bytes, not objects.** `irep->pool[]` holds
  `mrb_pool_value` records (type tag, length, byte pointer), not `mrb_value`s,
  so a literal's object has to live somewhere else.
- **Irep structs can be read-only.** `cdump` output and `class.c`'s core method
  tables are `static const` `mrb_irep` values (`MRB_IREP_STATIC`). A lazily
  filled per-irep cache would write to read-only memory on those builds.
- **Generated code runs in many VMs.** bc2cpp output runs in the same process as
  the interpreter, and a process may hold several `mrb_state`s (the harness
  does). A single static cache per call site returns the wrong VM's object when
  two VMs interleave, and after `mrb_close` a reused `mrb_state` address would
  match a stale entry.

The GC also needs a way to keep a literal alive without tracing it. A
persistent flag does that, but only if the object cannot reference another
collectable object: `mrb_gc_mark` traverses the class (`obj->c`) and an
fshared buffer, so skipping those children is sound only with restrictions.

## Decision

**Parser (mrbgems/mruby-compiler/core/parse.y).** The lexer reads each comment
line through `comment_line`. A `frozen_string_literal: true|false` key is
matched case-insensitively, with `-` and `_` treated alike, and only while no
token has been returned (`p->token_seen`). A magic comment after code is
ignored, as in CRuby. The line is read into a 256-byte buffer, so the key must
start within the first 255 bytes of its line. The result is
`mrb_parser_state.frozen_string_literal`. An `eval` string is a separate
compilation and does not inherit the flag.

**Compiler (codegen.c).** Under the flag, a string whose parts are all literal
compiles to one `OP_FSTRING`. This covers plain literals, heredocs without
interpolation and `%w`/`%W` words without interpolation. Interpolated strings
keep `OP_STRING` and `OP_STRCAT`, and so do symbol arrays, whose `gen_intern`
peephole rewrites `OP_STRING` to `SYMBOL`. Adjacent literal parts are joined at
compile time so that the pool holds one string.

`OP_FSTRING` is appended after `OP_STOP`. Inserting it after `STRING` would
renumber every later opcode, and bytecode produced by the old compiler would
stop loading. With the append, a file without the magic comment compiles to
byte-identical bytecode (checked on `mrblib/kernel.rb`). The compiler's
`merge_op_string` peephole folds only `OP_STRING`, so a frozen literal is never
folded into a method-call result.

**Runtime (src/string.c, src/vm.c).** `OP_FSTRING` calls
`mrb_frozen_literal(mrb, bytes, len)`, which returns the VM's one frozen String
for those bytes. The VM keeps a hash on `mrb_state` (`frozen_literals`, marked
as a GC root and not a global variable, so `global_variables` does not list
it), keyed by the bytes' Symbol. Interning the bytes costs no String allocation
per lookup. A miss creates the String, freezes it, marks it persistent and
stores it.

**Persistence (src/gc.c, src/class.c, object.h).** `MRB_FL_OBJ_PERSISTENT` is
bit 11. The predicate `MRB_OBJ_PERSISTENT_P` is type-qualified to
`MRB_TT_STRING`: no bit is free for every object type (classes use bits 17-19,
environments 8-18), but bit 11 is past every String flag (0-10). Four rules
follow:

- `is_dead` is false for a persistent object, so the sweep leaves it on its
  page and `mrb_object_dead_p` agrees. The generational sweep does not repaint
  survivors, so the exemption cannot live only in the sweep loop.
- `gc_mark_children` returns after `paint_black` for a persistent object and
  skips its class and children.
- `mrb_obj_set_persistent` refuses an unfrozen String, a String whose class is
  not `String`, and one with an fshared buffer. These are the only references a
  String can hold to another collectable object: a String has no ivar table
  here (`obj_iv_p`), and a `SHARED` buffer refers to a malloc'd refcount, not a
  GC object.
- `prepare_singleton_class` raises FrozenError for a persistent object, so its
  class stays `String`, which the mark skips.

Teardown needs no special path: `mrb_gc_destroy` frees every heap slot through
`obj_free(end=TRUE)`. `free_heap` does not consult the flag, so nothing clears it at close,
and `obj_free` does not read it either.

**bc2cpp (tools/bc2cpp).** `insn_decoder.rb` decodes `FSTRING` to the `STRING`
op with `Insn#frozen_literal` set, so every pass that reads String loads sees
the op it already knows. Only two things change: the `STRING` arm emits
`mrb_frozen_literal(M, "...", len)` (`codegen_insn.rb`), and
`escape_analysis.rb` reports a frozen literal as a failed creation, since it is
not a fresh allocation. `BC2CPP_FROZEN_LITERALS=0` makes the arm emit the old
`mrb_str_new_cstr` for those sites.

**Build.** `patches/mruby-frozen-string-literal-persist.patch` is added to the
patch chain in `cmake/build-mruby.cmake` (last, since it touches files the other
patches touch) and to `scripts/mruby/standalone_prep.bash`. The build regenerates
`y.tab.c` from `parse.y`, so the patch carries no generated file.

**Deviations from the original design.**

- *Per content, not per site.* Two literal sites with the same bytes in one VM
  share one object, as CRuby's fstring table does. "Created once per literal
  site per VM" still holds: each site gets exactly one object for its life.
- *No static cache in bc2cpp.* A per-call-site static keyed by `mrb_state` was
  rejected: it thrashes between interleaved VMs and can match a reused address.
  The per-VM table is used instead, so both paths share one identity rule.
- *The flag is not what keeps a literal alive.* The table is a root, so the
  literal would survive without the flag. The flag is implemented as specified,
  and the check exercises it directly with an unrooted persistent String.

## Consequences

- Files with the magic comment get CRuby's frozen-literal semantics on the
  interpreter and the compiled path. Files without it are unchanged: the same
  bytecode, and the same generated C++ with and without `BC2CPP_FROZEN_LITERALS`.
- Interpolated strings, `dup` and substrings stay unfrozen, as in CRuby.
- **Divergence:** a persistent literal raises `FrozenError` on
  `singleton_class`, where CRuby permits a singleton class on a frozen String.
  The refusal is what keeps the mark sound.
- **Divergence:** `mrb_obj_set_persistent` refuses a String of another class,
  such as a String subclass. Only literals (class `String`) are persistent.
- **Memory:** a persistent literal is not freed until `mrb_close`, and the
  table keeps one object per distinct content per VM. A program that evaluates
  many distinct magic-comment strings grows memory until the VM closes. Each
  distinct content also interns one Symbol, which lives as long as the VM.
- **Speed:** each load of a frozen literal costs one Symbol intern and one hash
  lookup. This was not measured. A per-site cache would avoid it, but it needs a
  writable slot per site, which the ROM irep and per-VM rules above rule out.
- Bytecode from older compilers still loads: the opcode is appended.
- bc2cpp's analysis tables need no new entries, because `FSTRING` decodes to
  the `STRING` op.
- Follow-ups: a measured benchmark of frozen-literal loads; a decision on
  whether the CRuby behaviour for `singleton_class` on a frozen String should be
  matched.

Verification is in `scripts/bc2cpp/frozen_literal_persist_check.rb`: parity of
interpreted and compiled code, `FrozenError` on mutation, identity across
`mrb_full_gc`, two VMs in one process with a closed VM's address reused,
unrooted persistence, and the kill switch. The check failed when the kill switch
was set, so its parity rows discriminate.
