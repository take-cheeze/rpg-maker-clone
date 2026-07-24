#!/usr/bin/env bash

set -eux -o pipefail

# Fetch a small, complete RPG Maker MV project to use as a test bed for the
# JavaScript-maker (MV) support. KinoAR/Lunatic-Core ships the full MV
# corescript (js/rpg_*.js + js/libs/pixi.js), a data/*.json database and img/
# assets, so it boots our embedded JS host (quickjs-ng) to Scene_Title.
#
# It is downloaded here (into the git-ignored data/ dir), never vendored, so the
# MV engine and game assets are not redistributed by this repository — the same
# approach used for the RPG Maker 2000 test game (download-nepheshel.bash).

mkdir -p "$(dirname "$0")/../data"
cd "$(dirname "$0")/../data"

if [ ! -d Lunatic-Core ]; then
    git clone --depth 1 https://github.com/KinoAR/Lunatic-Core.git Lunatic-Core
fi
