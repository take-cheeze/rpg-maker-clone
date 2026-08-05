#!/usr/bin/env bash

set -eux -o pipefail

mkdir -p $(dirname $0)/../data

cd $(dirname $0)/../data

# `wget -nv` / `unar -q`: without a terminal wget still prints a dot-progress
# line per 50 KiB and unar names every file it extracts, which is thousands of
# lines of CI log for one archive. Errors and the final summary still print.
if [ ! -f Nepheshel206beta.zip ] ; then
    wget -nv -O Nepheshel206beta.zip "https://til.sakura.ne.jp/soft_free/nepheshel/Nepheshel206beta.zip"
fi

if [ ! -d Nepheshel206beta ] ; then
    unar -q Nepheshel206beta.zip
fi
