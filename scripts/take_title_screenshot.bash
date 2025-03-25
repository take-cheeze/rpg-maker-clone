#!/usr/bin/env bash

set -eux -o pipefail

cd $(dirname $0)/..

display_name=:95
display_size=320x240

mkdir -p ss
chmod 777 ss

cat <<EOS > ./scripts/docker_script.bash
set -eux -o pipefail

if [ ! -d "\$HOME/.wine" ] ; then
    # wine winecfg /v
    # wineserver -w
    winetricks -q fakejapanese_ipamona
fi

#    -c:v libx264rgb -crf 0 -preset ultrafast -color_range 2 \
#    -c:v libx265 -x265-params lossless=1 -preset ultrafast \

ffmpeg \
    -loglevel panic -y \
    -thread_queue_size 1024 \
    -f x11grab -framerate 60 -video_size ${display_size} -i ${display_name} \
    -f pulse -ac 2 -i default \
    -c:v libx264rgb -crf 0 -preset ultrafast -color_range 2 \
    /proj/ss/out.mkv &
ffmpeg_pid=\$!
wine /proj/data/Nepheshel206beta/Nepheshel206Rbeta/RPG_RT.exe &
rpgrt_pid=\$!
sleep 8
xwd -root -silent | convert xwd:- png:/proj/ss/title.png
xdotool keydown Up
sleep 0.1
xdotool keyup Up
xwd -root -silent | convert xwd:- png:/proj/ss/title2.png
xdotool keydown Return
sleep 0.1
xdotool keyup Return
kill -INT \${ffmpeg_pid}
wait
ps
EOS

font_ar=opfc-ModuleHP-1.1.1_withIPAMonaFonts-1.0.8.tar.gz
if [ ! -f "./data/${font_ar}" ] ; then
    wget "https://web.archive.org/web/20190309175311/http://www.geocities.jp/ipa_mona/${font_ar}" -O "data/${font_ar}"
fi

docker-wine \
    --local=takecheeze/docker-wine \
    --volume=.:/proj \
    --volume=./data/${font_ar}:/home/wineuser/.cache/winetricks/ipamona/${font_ar} \
    --xvfb=${display_name},0,${display_size}x24 \
    --notty \
    bash /proj/scripts/docker_script.bash
