- bc2cpp: `NativeCallbacks.analyze` scans each C body once, not once per registration that reaches it. The closures
  are unchanged; the analysis takes about 2 s instead of about 38 s on the repo's native sources.
