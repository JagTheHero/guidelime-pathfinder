#!/bin/bash
# Build Detour tiles for both continents in a memory-capped scope.
cd "$(dirname "$0")/../data"
for m in Azeroth Kalimdor; do
	mkdir -p nav/$m
	systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=0 nice -n 19 ../build/navbuild tiles geo/$m nav/$m ${1:-12}
done
