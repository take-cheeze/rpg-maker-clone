- **CI can use the CORS proxy's R2 cache too**: the `build` and `wasm` jobs
  now route their third-party archive/asset downloads (Nepheshel, PrayforYou,
  FreePats, the default font, and the RPG Maker 2000/XP RTP installers)
  through `$CORS_PROXY_URL` when the `CORS_PROXY_URL` repository secret is
  set, falling back to a direct fetch as before when it isn't. This only
  matters when the existing `actions/cache` step for those downloads misses;
  the common path is unchanged. Setup in `docs/cors-proxy.md`; rationale in
  `docs/adr/0043-ci-uses-cors-proxy-cache.md`.
