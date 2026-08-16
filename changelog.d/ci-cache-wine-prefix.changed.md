- CI: the `build` job now caches `~/.wine` (the shared `WINEPREFIX`
  `rtp_install.bash` / `rtp_xp_install.bash` install into), keyed like the
  existing RTP zip cache. `rtp_install.bash` and `rtp_xp_install.bash` each
  check for their RTP's install directory in `WINEPREFIX` first and skip the
  wine round-trip (`winecfg` + the RTP installer under Xvfb) entirely on a
  cache hit, so a warm cache turns "Download RTP" into a couple of `ls`
  checks instead of two wine installs.
