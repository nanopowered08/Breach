#!/bin/sh
# Add a mission code (URL or local file) to tests/data/, re-embed every map there, and print the report.
#   sh tools/addmap.sh https://gist.githubusercontent.com/<user>/<id>/raw/.../thepeacemaker.txt
#   sh tools/addmap.sh ../TheNewMap.base64
# Run from the breach-codec directory.
set -e
src="$1"
[ -n "$src" ] || { echo "usage: sh tools/addmap.sh <url-or-file> [name]"; exit 1; }
name="${2:-$(basename "$src")}"
mkdir -p tests/data
case "$src" in
  http://*|https://*) curl -L -s -f "$src" -o "tests/data/$name" || { echo "download failed (check the URL / connection)"; exit 1; } ;;
  *) cp "$src" "tests/data/$name" ;;
esac
echo "saved tests/data/$name ($(wc -c < "tests/data/$name") bytes)"
sh tools/embed.sh tests/data/* > tests/_embedded.luau
luau tests/localfile.luau
