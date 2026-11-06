#!/bin/sh
# Copies the addon into WoW: Forever's AddOns folder (run after every upgrade, then /reload in game).
set -e
SRC="$(dirname "$0")/../addon/Guidelime_Pathfinder"
DST="$HOME/Games/umu/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/Guidelime_Pathfinder"
mkdir -p "$DST"
rsync -a --delete "$SRC/" "$DST/"
echo "installed to $DST"
