- **bc2cpp** compiles two more real shapes on the optcarrot scoping probe,
  both general bc2cpp gaps (ENSURE_DISPATCH_MERGE_SUPPORT and
  KEYWORD_HASH_LEXICAL_SELF_SUPPORT). `recognize_ensure_region` now accepts
  mrbc's `dispatch` tail-merge — a jump from inside a protected `ensure`
  body landing exactly on the handler's own address (an `if`-branch's
  normal exit merging onto the region) — remapping it to a label just after
  the RAII guard's scope, where leaving the C++ scope runs the ensure body
  exactly like the VM's inline EXCEPT/ensure-body/RAISEIF run would; jumps
  onto that address from outside the protected range are now rejected
  outright. And KEYWORD_HASH_POSITIONAL_SUPPORT, when its every-registry-
  def gate declines a keyword call onto a POLY name whose defs disagree,
  now retries against the one def an *implicit-self* site can reach, proven
  reachable by the existing LEXICAL_SELF selector (owner subclass-free,
  compiled-clean, not runtime-installed). The optcarrot probe goes
  99.5%→99.7% (381→382; `PPU#initialize`'s `reset(mapping: false)` and
  `NES#run`'s `ensure dispose end` now compile, and the probe's last
  `unhandled opcode EXCEPT` is gone); the real project's whole-program
  diagnostic — stats report, raw output and shipped method set — is
  byte-identical with and without the change.
