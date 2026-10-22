# shellcheck shell=bash
# Shared preparation of the script-driven mruby builds that run rake directly
# instead of through cmake/build-mruby.cmake: scripts/maix/mruby_build.bash (the
# `maix` cross library) and scripts/bc2cpp/closed_build.bash (the native `closed`
# bc2cpp build, build_config.rb). Sourced, with `root` set to the repository
# root: checks the tools, fetches and verifies the Unicode tables the rake-time
# generators read, and exports cp932_table and
# jis0208_table.

tables="$root/.native-build-tables"

for tool in ruby rake bison gperf; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found on PATH -- see ${BASH_SOURCE[1]:-$0} for what it needs" >&2
    exit 1
  fi
done

mkdir -p "$tables"
# Copies each table from data/unicode-mappings/ (vendored verbatim from
# unicode.org) into $tables and checks it against the sha256 flake.nix pins
# (base64, as Nix prints) -- same bytes Nix would hand the build, not a
# lookalike. Keep the pins in sync with data/unicode-mappings/README.md.
fetch_table() {
  local src="$1" dest="$2" want="$3"
  cp "$src" "$dest"
  local got
  got="$(python3 -c 'import hashlib,base64,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$dest")"
  if [ "$got" != "$want" ]; then
    echo "hash mismatch for $dest" >&2
    echo "  flake.nix pins $want" >&2
    echo "  downloaded     $got" >&2
    exit 1
  fi
}
fetch_table "$root/data/unicode-mappings/bestfit932.txt" \
  "$tables/bestfit932.txt" \
  'JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE='
fetch_table "$root/data/unicode-mappings/JIS0208.TXT" \
  "$tables/JIS0208.TXT" \
  'HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc='

# The mruby submodules are pinned to fork commits that already carry every
# patch the build used to apply (docs/patch-fork-tracking.md), so nothing is
# applied here.

export cp932_table="$tables/bestfit932.txt"
export jis0208_table="$tables/JIS0208.TXT"
