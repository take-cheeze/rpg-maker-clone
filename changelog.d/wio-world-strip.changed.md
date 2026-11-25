- **Wio build**: the wio-only mrblib rewrites (`scripts/wio/strip_*.rb`) now
  apply to the closed world bc2cpp compiles for the VM-free firmware. Before,
  they rewrote gem `rbfiles` that the VM-free build never loads, so none of
  them reached the firmware. Helpers with one caller are now folded into
  their caller by default. This saves about 14 KB of flash (QSPI -15.4 KB,
  internal +1.0 KB) and 284 B of RAM. `WIO_WORLD_STRIP=0` turns it off. A
  comma list such as `WIO_WORLD_STRIP=inline,clock` picks the passes,
  including the opt-in `probes`, `clock` and `debug`. `debug` saves about
  25 KB but drops the `[RPG2k]`/`[RGSS]` logs of recovered errors.
