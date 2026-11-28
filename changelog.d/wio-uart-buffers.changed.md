- **Wio Terminal**: the unused hardware UARTs (Serial1, Serial2) get 16-byte ring
  buffers instead of 256-byte ones, which frees about 1 KB of static RAM for the
  heap. USB serial and flashing over USB are unchanged.
