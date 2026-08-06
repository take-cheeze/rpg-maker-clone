#!/usr/bin/env python3
"""Package the MIDI patch set into Emscripten data files small enough to deploy.

The browser build mounts the FreePats patch set at /timidity so SDL_mixer's
TiMidity synthesiser can find its instruments (ADR 0026).  Doing that with
emcc's --preload-file folds the patches into the single index.data, which is
~36 MiB with the MV sample and the UI font alongside them -- and Cloudflare
Pages, where `/preview` deploys, rejects any file over 25 MiB.  GitHub Pages
allows 100 MiB, so the published page was fine and only PR previews broke.

So the patches are packaged separately here, split across as many data files as
it takes to stay under a size budget, using the same tools/file_packager.py that
--preload-file drives internally.  The generated loaders are concatenated into
one timidity.js, which the page loads ahead of the runtime script: each loader
registers an Emscripten run dependency, so main() does not start until every
package has unpacked.  TiMidity never sees the seam -- the packages write into
one MEMFS tree and it resolves patches through its own search path at song-load
time, long after all of them have landed.

The split is by size alone and carries no meaning: patches are bin-packed
largest-first into whichever package is currently smallest, so the only
invariant is that no single file exceeds the budget.  Re-running after the patch
set changes re-balances it, and the page does not care how many packages result.

Always writes timidity.js, even with no patches installed, so the page's script
tag resolves rather than 404ing on a build that deliberately ships without them.
"""

import argparse
import os
import subprocess
import sys

# Cloudflare Pages' per-file ceiling is 25 MiB. Aim well under it: the packager
# adds its own framing, and a patch set that grows should cost another package
# rather than creeping up on the limit.
DEFAULT_BUDGET_MIB = 16


def collect(patch_dir):
    """Every file under `patch_dir`, largest first, as (size, path, relpath)."""
    found = []
    for parent, _, names in os.walk(patch_dir):
        for name in names:
            path = os.path.join(parent, name)
            found.append((os.path.getsize(path), path,
                          os.path.relpath(path, patch_dir)))
    found.sort(reverse=True)
    return found


def bin_pack(files, budget):
    """Greedy largest-first bin packing into groups of at most `budget` bytes.

    Largest-first is what keeps this from degenerating: a 2.4 MiB patch placed
    last has nowhere to go, whereas placed first it decides the shape of a
    package the small ones then fill in.
    """
    groups = []
    sizes = []
    for size, path, rel in files:
        target = None
        for i, used in enumerate(sizes):
            if used + size <= budget:
                if target is None or used < sizes[target]:
                    target = i
        if target is None:
            groups.append([])
            sizes.append(0)
            target = len(groups) - 1
        groups[target].append((path, rel))
        sizes[target] += size
    return groups, sizes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("patch_dir", help="assets/timidity")
    parser.add_argument("out_dir", help="where to write timidity*.data and "
                                        "timidity.js")
    parser.add_argument("--file-packager", required=True,
                        help="path to Emscripten's tools/file_packager.py")
    parser.add_argument("--budget-mib", type=int, default=DEFAULT_BUDGET_MIB,
                        help=f"per-package ceiling (default {DEFAULT_BUDGET_MIB})")
    parser.add_argument("--mount", default="/timidity",
                        help="virtual filesystem path to mount the patches at")
    args = parser.parse_args()

    budget = args.budget_mib * 1024 * 1024
    os.makedirs(args.out_dir, exist_ok=True)
    loader_path = os.path.join(args.out_dir, "timidity.js")

    # Packages from a previous, differently-shaped split would still be
    # uploaded and loaded, mounting patches this build did not choose. Clear
    # them before writing anything, including on the no-patches path, where a
    # switch from ON to OFF would otherwise strand them.
    for name in os.listdir(args.out_dir):
        if name.startswith("timidity") and name.endswith((".data", ".js")):
            os.remove(os.path.join(args.out_dir, name))

    files = collect(args.patch_dir) if os.path.isdir(args.patch_dir) else []
    if not files:
        # A build that ships no patches still wants the script tag to resolve.
        # src/sdl_audio.cxx finds no config, warns, and the page says so.
        with open(loader_path, "w") as out:
            out.write("// No MIDI patch set was packaged into this page; a "
                      ".mid will not play.\n"
                      "// Run scripts/download-freepats.bash and rebuild. See "
                      "ADR 0026 / 0031.\n")
        print(f"timidity: no patches in {args.patch_dir}; wrote an empty "
              f"{loader_path}")
        return 0

    groups, sizes = bin_pack(files, budget)
    loaders = []
    for i, group in enumerate(groups):
        data = os.path.join(args.out_dir, f"timidity{i}.data")
        js = os.path.join(args.out_dir, f"timidity{i}.js")
        cmd = [sys.executable, args.file_packager, data,
               f"--js-output={js}"]
        cmd.append("--preload")
        cmd += [f"{path}@{args.mount}/{rel}" for path, rel in group]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            sys.stderr.write(result.stdout + result.stderr)
            sys.stderr.write(f"timidity: file_packager failed on package {i}\n")
            return 1
        with open(js) as handle:
            loaders.append(handle.read())
        os.remove(js)  # folded into the single loader below
        print(f"timidity: package {i}: {len(group)} files, "
              f"{sizes[i] / 1048576:.1f} MiB")

    with open(loader_path, "w") as out:
        out.write("// GENERATED by scripts/pack-timidity-data.py -- do not "
                  "edit.\n"
                  "// One Emscripten file_packager loader per timidity*.data, "
                  "concatenated so\n"
                  "// the page needs a single script tag however many packages "
                  "the split made.\n")
        out.write("\n".join(loaders))

    total = sum(sizes)
    print(f"timidity: {len(files)} files, {total / 1048576:.1f} MiB across "
          f"{len(groups)} package(s), largest "
          f"{max(sizes) / 1048576:.1f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
