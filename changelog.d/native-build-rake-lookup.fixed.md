- **`scripts/native-build-without-nix.bash` finds a version-manager `rake`.** A
  version manager (rbenv, asdf, rvm) puts `rake` in a per-version bin that is only
  on an *interactive* PATH, so the script's `command -v rake` missed it even
  though `rake` works in a terminal — and its advice, "gem install rake", is then
  both wrong and, behind a proxy that blocks rubygems, impossible. It now asks
  Ruby where its own gem executables live (`Gem.bindir`) before giving up, and
  says what it actually tried when it does.
