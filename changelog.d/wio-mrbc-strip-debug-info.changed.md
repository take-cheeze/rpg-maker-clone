- **Wio Terminal: stripped mrbc debug info (line numbers, local-variable
  names) from every gem's compiled Ruby.** PSP's own build config already
  did this (docs/adr/0047) for the same reason -- wio never got the sibling
  fix. Real relink: 112,920 bytes of flash and 104,688 bytes of RAM
  recovered from one config change; RAM headroom goes from 46,384 to
  151,072 bytes (of a 196,608-byte budget) -- by far the largest RAM win
  found this round. See ADR 115.
