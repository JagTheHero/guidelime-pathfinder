#!/bin/sh
# Copies the addon and its two path data addons into WoW: Forever's AddOns folder (run after every upgrade, then
# /reload in game; restart the game instead when the addons or their TOC file lists change).
set -e
ADDONS="$HOME/Games/umu/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"
for name in Guidelime_Pathfinder Guidelime_Pathfinder_Azeroth Guidelime_Pathfinder_Kalimdor; do
	mkdir -p "$ADDONS/$name"
	rsync -a --delete "$(dirname "$0")/../addon/$name/" "$ADDONS/$name/"
done
echo "installed to $ADDONS"
