- **CI**: the wasm job's ccache cache was keyed on `github.sha`, so nearly
  every push minted a fresh multi-hundred-MB cache entry that almost never
  got reused (the next commit has a different sha). On a commit-heavy repo
  that flooded `github.com/<repo>/actions/caches`, pushing GitHub's
  10GB-per-repo cap into evicting the still-useful Nix store, RTP, wine
  prefix and game-data caches to make room. The key now rotates weekly
  instead, bounding growth to roughly one new entry per week while still
  refreshing ccache's contents regularly.
