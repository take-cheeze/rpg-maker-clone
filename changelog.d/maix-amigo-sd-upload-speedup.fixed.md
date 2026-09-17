- **Maix Amigo SD upload speed**: `scripts/maix_sd_upload.py` (used to push
  real game data onto a connected Amigo's microSD card) used to pace every
  64-byte chunk with a blind 50ms sleep, guessing at how long the
  firmware's SD write would take -- the dominant cost of any transfer of
  meaningful size (hours for a real game). `app/wio/src/
  maix_sd_upload_main.cxx` now batches many small reads (still 64 bytes
  each, the UARTHS RX ring buffer's own limit) into a 2KB accumulation
  buffer before one SD write, and the host waits for an explicit
  `CHUNK_OK` after each instead of guessing a sleep duration; both sides
  also run at 1500000 baud instead of 115200. Measured on real hardware:
  a 1.3MB file that projected to roughly 17 minutes under the old scheme
  now takes about 30 seconds, with content verified byte-for-byte via a
  CRC32 round-trip during development (not shipped).
