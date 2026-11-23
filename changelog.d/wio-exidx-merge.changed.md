- **Wio Terminal**: the firmware link groups functions by their unwind entry,
  so ld merges equal `.ARM.exidx` entries (about 22 KB less flash). It links
  twice; `WIO_EXIDX_MERGE=0` links once.
