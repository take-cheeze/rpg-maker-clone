- **bc2cpp census** now re-asks a refused receiver origin through the exception handler edges by default, so 115
  more census sites get an exact origin on the wio shipped pass. `BC2CPP_SITE_ORIGIN_EXCEPTIONS=0` turns it off.
  Origin table only; generated C++ is byte-identical. See `docs/bc2cpp-dynamic-site-census.md`.
