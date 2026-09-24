- **Wio Terminal: CP932 tables shrink from 75.9 KB to 16.4 KB of flash.**
  They are now a dense per-lead-byte decode table, and the user-defined area
  is computed rather than stored. On wio, saving encodes by scanning those
  tables instead of keeping the 38 KB reverse table. Other targets keep the
  reverse table, and decoding is faster everywhere.
  `scripts/cp932_tables_check.rb` proves both directions identical to the old
  tables for all 65,536 inputs (ADR 0217).
