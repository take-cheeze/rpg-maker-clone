- **Maix Amigo SD uploader**: `maix_sd_upload` firmware plus
  `scripts/maix_sd_upload.py` push files to the microSD card over USB
  serial (same PING/PUT protocol as the Wio loader), for machines without
  a card reader. Verified against real hardware, which also confirmed the
  K210 download/console port is the second UART. See `app/maix/README.md`.
