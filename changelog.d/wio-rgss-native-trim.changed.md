- **Wio Terminal: 44.8 KB less flash from RGSS features wio cannot reach.**
  TrueType text rendering is compiled out (text on wio was always the
  shinonome bitmap font), and so are the native `RGSS::Tilemap` and
  `RGSS::Window`, which RPG2k does not use. Both classes now raise
  `NotImplementedError` if constructed. The desktop-only render and audio
  probes are also stripped from wio's bytecode. `FLASH` overflow falls from
  624,164 to 579,320 bytes (ADR 0220).
