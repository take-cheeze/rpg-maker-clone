- The map-walk port's export format packs a cell into 2.5 bytes — a byte of
  lower-layer atlas index, a byte of upper, and a nibble of passability —
  where it used five. Both are the source data's own ranges: across all 535
  exportable Nepheshel maps the largest atlas index referenced is 145, and no
  cell has ever used a passability bit outside the low nibble. The iPod nano
  7G app's `.bss` drops from 150 KB to **108 KB** (336 KB when the port
  landed), and the Wio Terminal's `wio_walk` firmware now takes **128×128**
  maps — the same bound the nano has — in less SRAM than its old 64×64 cap
  cost. Format version 4: re-export before installing. See ADR 93.
