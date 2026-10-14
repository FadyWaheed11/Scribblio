#!/bin/zsh
# Universal build with an ad-hoc signature and a zip for GitHub Releases.
set -e
cd "$(dirname "$0")"
SCRIBBLIO_SIGN=- zsh build.sh universal
mkdir -p dist
rm -f dist/Scribblio.zip
ditto -c -k --keepParent build/Scribblio.app dist/Scribblio.zip
ls -lh dist/Scribblio.zip
