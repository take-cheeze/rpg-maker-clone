# shellcheck shell=bash
# Shared preparation of the script-driven mruby builds that run rake directly
# instead of through cmake/build-mruby.cmake: scripts/bc2cpp/closed_build.bash
# (the native `closed` bc2cpp build, build_config.rb). Sourced, with `root` set to the repository
# root: checks the tools, fetches and verifies the Unicode tables the rake-time
# generators read, applies the mruby patches, and exports cp932_table and
# jis0208_table.

tables="$root/.native-build-tables"

for tool in ruby rake bison gperf; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found on PATH -- see ${BASH_SOURCE[1]:-$0} for what it needs" >&2
    exit 1
  fi
done

mkdir -p "$tables"
# url, destination, and the sha256 flake.nix pins for it (base64, as Nix
# prints) -- same bytes Nix would hand the build, not a lookalike. Keep the
# pins in sync with flake.nix.
fetch_table() {
  local url="$1" dest="$2" want="$3"
  if [ ! -s "$dest" ]; then
    curl -fsSL -o "$dest" "$url"
  fi
  local got
  got="$(python3 -c 'import hashlib,base64,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$dest")"
  if [ "$got" != "$want" ]; then
    echo "hash mismatch for $dest" >&2
    echo "  flake.nix pins $want" >&2
    echo "  downloaded     $got" >&2
    exit 1
  fi
}
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt' \
  "$tables/bestfit932.txt" \
  'JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE='
fetch_table \
  'https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT' \
  "$tables/JIS0208.TXT" \
  'HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc='

# Same patch list cmake/build-mruby.cmake applies before every rake build --
# keep the two in sync. (Absolute patch paths: the apply script cds into the
# submodule first.)
apply_patch() {
  "$root/scripts/apply_mruby_patch.bash" "$1" "$2"
}
for p in mruby-colon3-assign-setmcnst mruby-dollar-bang-scoped \
  mruby-defined-keyword mruby-nomemoryerror-reentrant-alloc \
  mruby-gc-type-live-counts mruby-rdata-ivar-slots \
  mruby-io-maxpathlen-fallback mruby-io-direct-puts \
  mruby-io-file-size-bigint mruby-io-read-direct \
  mruby-force-no-cxx-exception-escape-hatch mruby-presym-compact-table \
  mruby-cdump-const-reps mruby-no-irep-debug \
  mruby-expose-misc-bodies mruby-expose-index-bodies mruby-expose-collection-op-bodies; do
  apply_patch "$root/3rd/mruby" "$root/patches/$p.patch"
done
apply_patch "$root/3rd/mruby-stringio" "$root/patches/mruby-stringio-native-getbyte.patch"
apply_patch "$root/3rd/mruby-stringio" "$root/patches/mruby-stringio-read-direct.patch"
apply_patch "$root/3rd/mruby-marshal" "$root/patches/mruby-marshal-psp-wio-onigmo-optional.patch"

export cp932_table="$tables/bestfit932.txt"
export jis0208_table="$tables/JIS0208.TXT"
