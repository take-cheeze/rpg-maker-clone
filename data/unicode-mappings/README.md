# Unicode mapping tables

Vendored, unmodified copies of two Unicode Consortium mapping files. The
build reads them as `$cp932_table` and `$jis0208_table` (mruby-lcf's
`cp932_to_unicode.rb` and mruby-rgss's `gen_shinonome_data.rb`) and the
Nix flake passes them the same way (`flake.nix`).

| File | Source | sha256 (base64, as Nix prints) |
|------|--------|--------------------------------|
| `bestfit932.txt` | https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit932.txt | `JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE=` |
| `JIS0208.TXT` | https://www.unicode.org/Public/MAPPINGS/OBSOLETE/EASTASIA/JIS/JIS0208.TXT | `HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc=` |

The hashes are the same pins `flake.nix`, `scripts/mruby/standalone_prep.bash`,
`scripts/native/build-without-nix.bash`, `scripts/build/psp_docker.bash` and the
`psp`/`psp-smoke` CI jobs check. To update a table, replace the file, then
change the pin in every one of those places in the same commit.

The files carry Unicode's own copyright header and are redistributed under the
terms in their headers (https://www.unicode.org/terms_of_use.html).
