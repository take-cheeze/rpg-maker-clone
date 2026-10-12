- **Wio Terminal: measured what ADR 0400's typed save files cost in flash.** A real
  `env:wio_rgss_boot` link (arm-none-eabi 14.2.1) grows from 993,784 to 1,023,608
  bytes (+29,824; static RAM unchanged at 21,516). The image already overflowed the
  507,904-byte FLASH region by 485,880 bytes before the change, so no fallback
  build was added; the numbers are recorded in docs/adr/0400-typed-save-state.md.
