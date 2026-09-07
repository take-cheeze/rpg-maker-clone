- **Design record only, no emulator code yet:** ADR 93 proposes a phased
  Renode-based emulator for the Wio Terminal port, motivated by this
  session's `pushImage` colour bug having only been catchable by flashing
  real hardware. Checked upstream `renode/renode-infrastructure` source
  rather than just documentation: a SERCOM-SPI peripheral (`SAM_SPI`) and a
  SAMD21 GPIO PORT model already exist and are likely reusable, but no
  ILI9341/ST7789 display peripheral and no SD-over-SPI framing exist
  anywhere upstream — those would be new C# peripherals written for this.
  See `docs/adr/0093-wio-terminal-renode-emulator.md` for the phase
  breakdown and exit criteria.
