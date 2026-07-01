#!/usr/bin/env bash
#
# slice.sh — example wrapper for headless OrcaSlicer slicing.
#
# Usage:
#   ./slice.sh model.stl                 # normal slice
#   RAFT=1 ./slice.sh model.stl          # slice with the raft process profile
#   ./slice.sh a.stl b.stl c.stl         # multi-plate: auto-arrange several STLs
#
# Edit the variables below to point at your own OrcaSlicer binary and profiles.

set -euo pipefail

# --- configuration -----------------------------------------------------------

# Path to the OrcaSlicer executable (inside the app bundle / install dir).
ORCA="${ORCA:-/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer}"

# Machine (printer) profile. Point this at a bundled system profile or your own export.
MACHINE="${MACHINE:-$HOME/Library/Application Support/OrcaSlicer/system/Vendor/machine/Generic 0.4 nozzle.json}"

# Filament profile.
FILAMENT="${FILAMENT:-$HOME/Library/Application Support/OrcaSlicer/system/Vendor/filament/Generic PLA.json}"

# Process profile — clean by default, raft variant when RAFT=1.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${RAFT:-0}" == "1" ]]; then
  PROCESS="${PROCESS:-$SCRIPT_DIR/examples/process_raft.json}"
else
  PROCESS="${PROCESS:-$SCRIPT_DIR/examples/process.json}"
fi

# Where the gcode goes.
OUTDIR="${OUTDIR:-$SCRIPT_DIR/out}"

# --- run ---------------------------------------------------------------------

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <model.stl> [more.stl ...]" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# --arrange 1 auto-packs objects on the bed; harmless for a single STL,
# required when slicing multiple STLs onto one plate.
"$ORCA" \
  --arrange 1 \
  --slice 1 \
  --load-settings "$MACHINE;$PROCESS" \
  --load-filaments "$FILAMENT" \
  --outputdir "$OUTDIR" \
  "$@"

# OrcaSlicer writes plate_1.gcode (plate_2.gcode, ... for multi-plate).
# Rename the single-plate output to match the first model's basename.
FIRST_STL="$1"
BASENAME="$(basename "${FIRST_STL%.*}")"
if [[ -f "$OUTDIR/plate_1.gcode" ]]; then
  mv "$OUTDIR/plate_1.gcode" "$OUTDIR/$BASENAME.gcode"
  echo "wrote: $OUTDIR/$BASENAME.gcode"
fi
