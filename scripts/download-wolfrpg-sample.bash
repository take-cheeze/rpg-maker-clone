#!/usr/bin/env bash

set -eux -o pipefail

# Routes through the optional CI CORS proxy cache when CORS_PROXY_URL is set.
. "$(dirname "$0")/cors-proxy-url.bash"

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# The official WOLF RPG Editor (ウディタ / Woditor) distribution, "full"
# package: Editor.exe + Game.exe + the bundled **sample game** (the RPG Basic
# System, its four maps, chipsets, character sheets and audio) under
# WOLF_RPG_Editor3/Data. SmokingWOLF publishes every release on GitHub
# (https://github.com/smokingwolf/tool_wolf_rpg_editor/releases -- the archive
# page https://smokingwolf.github.io/tool_wolf_rpg_editor/ points there), so
# unlike the RPG Maker XP/VX test beds this one is a first-party, freely
# downloadable project written by the editor's own author.
#
# The version is pinned: the sample game's data files are the format
# specification this engine's Wolf loader (mruby-wolf) is validated against
# (scripts/wolf_testbed_check.rb), and a moving target would make a parser
# regression indistinguishable from a format change. 3.724 is a v3.5+-era
# release: its .mps / CommonEvent.dat / *DataBase.dat bodies are LZ4-packed
# and its strings UTF-8, the format every current Woditor release writes.
#
# See download-nepheshel.bash for why wget/unar are quietened.
VERSION=3.724

if [ ! -f "WolfRPGEditor_${VERSION}_full.zip" ] ; then
    wget -nv -O "WolfRPGEditor_${VERSION}_full.zip" \
        "$(proxied_url "https://github.com/smokingwolf/tool_wolf_rpg_editor/releases/download/v${VERSION}/WolfRPGEditor_${VERSION}_full.zip")"
fi

# The zip's top-level directory is WOLF_RPG_Editor3/; unpack it under a
# versioned directory so two pinned versions can coexist, and so the game
# directory this engine is pointed at is data/wolfrpg-sample-3.724/WOLF_RPG_Editor3.
if [ ! -d "wolfrpg-sample-${VERSION}" ] ; then
    mkdir -p "wolfrpg-sample-${VERSION}"
    unar -q -o "wolfrpg-sample-${VERSION}" "WolfRPGEditor_${VERSION}_full.zip"
fi
