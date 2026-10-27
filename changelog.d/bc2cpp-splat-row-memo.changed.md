- **bc2cpp** (`SPLAT_ROW_MEMO`): a guarded `send(*table[i])` on self now keeps a 256-entry memo per site, indexed
  by `i`. Each entry is a bit-for-bit copy of a list of immediates together with its arm. A matching list switches
  straight on that arm and skips the immediates scan and the length and Symbol tables. Any other list takes the
  tables and refills the entry, so frozen, unfrozen, rewritten and reassigned rows all stay exact. In the
  optcarrot probe `CPU#run` (`send(*DISPATCH[@opcode])`) falls from 1.63M to 1.47M instructions per frame, and the
  frame loop from 29.70M to 29.53M; startup is unchanged.
  `BC2CPP_SPLAT_ROW_MEMO=0` turns it off. See `docs/bc2cpp-splat-row-memo.md`; the new check is
  `scripts/bc2cpp/splat_row_memo_check.rb`.
