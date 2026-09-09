- **Removed a dead, shadowed `#vehicle_pixel` method in
  `RPG2k::Scene::Map`** — the class defined it twice; the first
  (non-interpolated) version was permanently unreachable behind the
  second, more complete one (which handles the currently-boarded vehicle
  and off-map vehicles correctly) from the moment both existed, regardless
  of call site. Found with a small Ripper-based scanner that tracks each
  method's real enclosing class rather than matching names by text — a
  sound check unlike general "unused method" hunting, since a
  redefinition-shadowed method is unreachable by construction, no dynamic
  dispatch to worry about. Applies to every target (this file is shared,
  unconditional source, not wio-only). See ADR 121.
