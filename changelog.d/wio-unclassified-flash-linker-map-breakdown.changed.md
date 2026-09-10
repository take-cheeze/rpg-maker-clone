- **Wio Terminal: broke docs/adr/0140's 312,105-byte "unclassified" flash
  category down to real object files via a real linker-map pass — no safe
  win found, and no source change.** Arduino framework/TFT_eSPI/FreeRTOS
  (14,590 / 21,052 / 2,002 bytes) are real, load-bearing vendor-library code
  already mostly `--gc-sections`-trimmed; newlib's civil-time stack (~3,000
  bytes) is reachable through mruby's own always-registered `Time` method
  table even though this project's code only calls `Time.now`; C++
  exception-support machinery (60,097 bytes gross) was already measured and
  deliberately not adopted by docs/adr/0134 for a real correctness reason;
  and the single largest piece, `mruby-rgss`/`mruby-lcf`/`mruby-marshal`'s
  own C++ implementation (100,020 bytes, including the still-compiled-in
  PNG/BMP decoder), is real, reachable application code. `wio_rgss_boot`
  still overflows by 675,960 bytes. See docs/adr/0141.
