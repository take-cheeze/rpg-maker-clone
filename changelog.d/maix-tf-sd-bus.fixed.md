- **Maix Amigo SD** now clocks the TF slot on the right bus: the uploader and
  the SD syscall layer use SPI0 (SCK 11 / MISO 6 / MOSI 10, CS 26) instead of
  the SD library's global object, which is bound to SPI1 with the wrong pins
  and could never reach the card.
