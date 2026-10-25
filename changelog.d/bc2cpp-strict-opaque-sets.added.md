- **bc2cpp:** opaque-register sets now use a `StrictKeySet` that raises
  `TypeError` on a non-Integer member in dev instead of silently missing;
  `BC2CPP_STRICT_KEYS=0` aliases it to plain `Set` (zero overhead).
