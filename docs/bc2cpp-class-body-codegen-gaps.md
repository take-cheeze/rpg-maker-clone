# Class-body codegen: gaps

Goal: compile a class body's bytecode IR the way method bodies are compiled (tools/bc2cpp/codegen_insn.rb), so the
body is C++ that runs once at gem init, not an OP_EXEC body or a CLASS_PROGRAM byte program. Measured with
`scripts/bc2cpp/class_body_report.rb --blockers --bytecode` on master (boot VM starts 157 per run).

Status key: **known** (measured), **gap** (needs code, not started), **unknown** (not measured yet), **skipped** (out
of scope for this step, listed so it is not forgotten).

## A. Opcodes the method codegen has no case for (known, counts from the report)

| Opcode | Uses | Why it matters | Status |
| --- | --- | --- | --- |
| `TDEF` | 2808 | a `def` in a class body, registered by the load | gap |
| `SETCONST` | 1038 | constant assignment; needs the lexical owner | gap (see B) |
| `EXEC` | 261 | nested class/module body entry | gap |
| `SDEF` | 207 | `def self.x` | gap |
| `CLASS` | 187 | `class X` (creates or reopens the class) | gap |
| `TCLASS` | 158 | class-body self for `class << self` and nested defs | gap |
| `DEF` | 159 | a def with a receiver-less owner | gap |
| `METHOD` | 159 | method object reads in a body | gap |
| `MODULE` | 74 | `module X` | gap |
| `ALIAS` | 24 | `alias` statement; a copy (stub proof, see D) | gap |
| `UNDEF` | 0 in boot set | not measured in the boot set | unknown |
| `SCLASS` | 0 in boot set | `class << self` as its own opcode | unknown |
| `OCLASS` | 0 in boot set | `Object` class read | unknown |

## B. Owner proof for constant writes (gap)

`SETCONST` needs the lexical owner of the name to emit `mrb_const_set` on the right class. `codegen_numeric_consts.rb`
and `lexical_consts.rb` resolve constant **reads** (`read_keys`) and record the SETCONST sites only as a join of class
sets. There is no **write** owner per SETCONST site, so the emitter has nothing to name. Gap: add a write-owner map
from the same CLASS/MODULE nesting that `lexical_consts.rb` walks.

## C. Entering a nested body from C++ (gap)

`EXEC`, `CLASS`, `MODULE`, `TCLASS` need class creation and the body's self. The CLASS_PROGRAM decoder already does
this (`mrb_vm_define_class`, `mrb_vm_define_module` in `load_compile.rb` PRELUDE). Gap: the generated body must call
the same helpers, not emit its own class creation, so reopen and superclass behaviour stay identical.

## D. Defs and the stub proof (gap, partly known)

A def's registration has to match what `mrblib_stubs.rb` drops. Known keep reasons from the stub-keep dump
(`BC2CPP_STUB_KEEP_DUMP`, branch `claude/stub-keep-reasons-dump-r5t1`): `copied_name` (alias/module_function copies,
e.g. `RGSS::Window#initialize`, `Array#sort!`), `no_irep` (defs without IR), `guard` (CORE_BLOCK_GUARD), `load_phase`
(one key). The codegen must not emit a def the stub proof keeps as bytecode, and must emit the rest.

## E. Statement blockers that keep a whole body as bytecode (known, skipped for this step)

- `control`: `If` at `numeric.rb:130` (core Numeric)
- `runtime`: `STDIN`, `STDOUT`, `STDERR` and `$` global writes at `io.rb:292–303` (core IO/File)
- `const_computed`: `Game::State::SYSTEM_SFX_SAVE_FIELD` (`lsd_io.rb:1143`), `LCF::Schema::DATABASE` and `MAP_UNIT`
  (`schema.rb:92`, `:1109`, lambdas), `RGSS::Audio::EXT_SPELLINGS` (`lib.rb:1161`)

These keep their body whatever the codegen does, so they are listed, not fixed here.

## F. Unknown (not measured)

- **LCF module body** still enters the VM at boot (`LCF#(block)`). Not explained by A–E. Likely the planner's `stays`
  decision in `load_compile.rb`. Measure with a planner dump before assuming it is codegen.
- **Text size** of compiled class bodies vs CLASS_PROGRAM. Wio's SRAM is tight (see `docs/bc2cpp-vm-entries.md`).
- **Boot starts saved** by compiling class bodies: at most the EXEC count (62) if every body compiles; not measured.
- **Width**: whether the new emitters are 32-bit clean (`bc2cpp-width`). Not checked.

## Next

1. Owner map for SETCONST writes (B), with a check on a fixture of nested classes.
2. Emit TDEF/DEF/SDEF through the stub proof's keep list (D).
3. Class entry through the existing helpers (C).
4. Fill F with measurements.
