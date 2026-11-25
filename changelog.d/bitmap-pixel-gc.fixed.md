- **Bitmap pixels** now count towards garbage collection: once the live pixel
  bytes grow past what the last collection kept, a full GC runs, and a pixel
  allocation that fails runs one and retries before raising `NoMemoryError`
  (logged as `[RGSS] no memory for ... bitmap pixels`) instead of halting.
  Dropped windows no longer pile up megabytes of pixels in battle on the Wio
  Terminal.
