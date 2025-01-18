#!/usr/bin/env bash

set -eux -o pipefail

cd $(dirname $0)/..

mkdir -p ss

cat <<EOS > ./scripts/docker_script.bash
set -eux -o pipefail

# wine winecfg /v
# wineserver -w
winetricks -q fakejapanese_ipamona

wine /proj/data/Nepheshel206beta/Nepheshel206Rbeta/RPG_RT.exe &
sleep 8
xwd -root -silent | convert xwd:- png:/proj/ss/title.png
xdotool keydown Up
sleep 0.1
xdotool keyup Up
xwd -root -silent | convert xwd:- png:/proj/ss/title2.png
xdotool keydown Return
sleep 0.1
xdotool keyup Return
EOS

docker-wine \
    --local=takecheeze/docker-wine \
    --volume=.:/proj \
    --xvfb=:95,0,320x240x24 \
    --notty \
    bash /proj/scripts/docker_script.bash
