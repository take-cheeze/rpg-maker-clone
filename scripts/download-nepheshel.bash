#!/usr/bin/env bash

set -eux -o pipefail

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

if [ ! -f Nepheshel206beta.zip ] ; then
    wget -O Nepheshel206beta.zip "https://til.sakura.ne.jp/soft_free/nepheshel/Nepheshel206beta.zip"
fi

if [ ! -d Nepheshel206beta ] ; then
    unzip Nepheshel206beta.zip
fi
