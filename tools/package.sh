#!/bin/sh
# Zips the addon for CurseForge: dist/Guidelime_Pathfinder-<version>.zip, with the addon folder at the top.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^## Version: *\([^\r]*\).*/\1/p' "$ROOT/addon/Guidelime_Pathfinder/Guidelime_Pathfinder.toc")"
OUT="$ROOT/dist/Guidelime_Pathfinder-$VERSION.zip"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
cd "$ROOT/addon"
zip -qr -9 "$OUT" Guidelime_Pathfinder -x '*.DS_Store'
echo "$OUT"
