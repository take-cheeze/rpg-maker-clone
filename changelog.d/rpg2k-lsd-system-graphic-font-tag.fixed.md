- **Change System Graphics' windowskin and font override now round-trip
  through .lsd saves correctly.** They were being written to, and read from,
  the wrong field of the save's system chunk (a hex-digits-as-decimal
  transcription slip), which only surfaced against a genuine third-party
  save or a save this engine exports being opened elsewhere.
