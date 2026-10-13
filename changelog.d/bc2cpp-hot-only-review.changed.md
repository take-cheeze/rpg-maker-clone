- The bc2cpp dead-fallback review list (`NOMETHOD_REVIEWED`, ADR 0226) now covers the eight sites that
  `Game::CommonEvent.singleton#eligible` and `Game::MoveRoute.singleton#same_route?` gained from ADR 0426,
  so the nightly `hot-only` check passes again. No generated code changes for the hot-only build.
