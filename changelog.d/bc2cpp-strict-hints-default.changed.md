- bc2cpp's runtime strict hint tier is on by default (ADR 0438): a wrong class hint on a receiver-hint site
  raises `BC2cppHintViolation` instead of dispatching by name. `BC2CPP_STRICT_HINTS=0` restores the previous output.
