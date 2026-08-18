- **PPSSPP's crash-recovery disassembler (`Common/x64Analyzer.cpp`) no
  longer hard-stops the emulator on an ordinary 8-bit memory access.** Its
  `X86AnalyzeMOV`, used by `Core/MemFault.cpp` to recover from a bad guest
  memory access under the x86-64 JIT/`JIT_IR` backends when
  `bIgnoreBadMemAccess` is set (headless mode's default), only recognized
  the 32/64-bit-register MOV opcodes (`0x89`/`0x8B`) and the immediate-store
  opcodes (`0xC6`/`0xC7`) — not `0x88`/`0x8A`, the 8-bit-register
  reg&harr;mem forms, which are what the JIT emits for any single-byte
  guest store/load (e.g. a MIPS `sb`). Hitting one during recovery fell
  into `X86AnalyzeMOV`'s own `default:` case (logging "Unhandled disasm
  case in write handler!"), which `MemFault.cpp` then treats as
  unrecoverable and halts the whole emulated process — even though
  `bIgnoreBadMemAccess` would otherwise have skipped the instruction and
  continued exactly as it already does for every other access width.
  `nix/patches/ppsspp-x64analyzer-8bit-mov.patch` (not yet upstreamed to
  `hrydgard/ppsspp`) adds both missing opcodes.

  Found chasing [ADR 0047](docs/adr/0047-psp-memory-budget.md)'s P1 bug 8
  (a `Bad memory access detected!` fatal halt inside mruby's
  `mrb_gc_init`, previously characterized as a JIT register-allocation
  bug). That characterization does not hold up: this patch is a real,
  verified fix (confirmed eliminating the fatal halt under both PPSSPP's
  x86 JIT and its `JIT_IR` backend, converting it to the same graceful
  "ignored" recovery every other store width already gets), but applying
  it does **not** get this EBOOT booting further — the guest-level
  condition that makes the GC heap-page pointer read as a near-null
  address at that point is still open, and new evidence (see the ADR)
  points away from a JIT-specific bug and toward something else entirely.
