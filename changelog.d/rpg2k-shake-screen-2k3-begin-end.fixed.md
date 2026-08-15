- **RPG2003's Shake Screen Begin/End continuous-strobe mode now works.** A
  Begin command used to silently do nothing instead of starting an
  indefinite shake, since the runtime never read the command's mode
  parameter at all and always fell back to a zero-duration one-shot shake.
