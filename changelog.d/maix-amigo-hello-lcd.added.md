- **Maix Amigo P0 bring-up**: `pio run -e maix_amigo` now builds a hello-world
  + LCD firmware for the Sipeed Maix Amigo (K210), using a custom
  `boards/sipeed-maix-amigo.json` since the K210 PlatformIO platform ships no
  Amigo board definition. See `app/maix/README.md`.
