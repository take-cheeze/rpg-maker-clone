#!/usr/bin/env bash

set -eux -o pipefail

cd $(dirname $0)/..

mkdir -p ss
chmod 777 ss

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

font_ar=opfc-ModuleHP-1.1.1_withIPAMonaFonts-1.0.8.tar.gz
if [ ! -f "./data/${font_ar}" ] ; then
    wget "https://web.archive.org/web/20190309175311/http://www.geocities.jp/ipa_mona/${font_ar}" -O "data/${font_ar}"
fi

docker-wine \
    --local=takecheeze/docker-wine \
    --volume=.:/proj \
    --volume=./data/${font_ar}:/home/wineuser/.cache/winetricks/ipamona/${font_ar} \
    --xvfb=:95,0,320x240x24 \
    --notty \
    bash /proj/scripts/docker_script.bash
