- LCF integer fields decode without a temporary `StringIO`, which the map
  renderer made dozens of per frame; less garbage-collector work on the Wio
  Terminal.
