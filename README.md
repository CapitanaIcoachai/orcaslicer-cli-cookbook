# OrcaSlicer CLI Cookbook

A practical, no-nonsense recipe book for driving **[OrcaSlicer](https://github.com/SoftFever/OrcaSlicer)** from the command line: headless slicing, rafts, and multi-plate arrangement — plus the **three undocumented bug-fixes** that cost people hours the first time they hit them.

Everything here is generic (Ender-3-like machine, generic PLA). Swap in your own machine/filament/process JSON profiles.

## Table of contents

- [Why CLI slicing?](#why-cli-slicing)
- [Finding the binary](#finding-the-binary)
- [(a) Headless slice — the basics](#a-headless-slice--the-basics)
- [(b) Slicing with a raft](#b-slicing-with-a-raft)
- [(c) Multi-plate / auto-arrange](#c-multi-plate--auto-arrange)
- [(d) The three fixes that cost hours](#d-the-three-fixes-that-cost-hours)
  - [Fix 1 — "Relative extruder addressing" error](#fix-1--relative-extruder-addressing-error)
  - [Fix 2 — raft parameters must be STRINGS](#fix-2--raft-parameters-must-be-strings)
  - [Fix 3 — split clean/raft process JSON + `machine;process` load order](#fix-3--split-cleanraft-process-json--machineprocess-load-order)
- [(e) Booleans on STL / lessons learned](#e-booleans-on-stl--lessons-learned)
- [Files in this repo](#files-in-this-repo)
- [License](#license)

---

## Why CLI slicing?

OrcaSlicer's GUI is great for one-off prints, but if you are:

- batch-slicing dozens of STLs,
- regenerating gcode every time a parametric CAD/Blender script changes a model,
- running slicing inside a script, CI job, or an automated pipeline,

…then the CLI is what you want. The catch: the CLI is **thinly documented**, and a few of its quirks fail *silently* or with cryptic errors. This cookbook collects the working incantations.

---

## Finding the binary

The OrcaSlicer executable lives *inside* the application bundle / install dir, not on your `PATH` by default.

```bash
# macOS
ORCA="/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"

# Linux (AppImage — extract or run directly)
# ORCA="/path/to/OrcaSlicer.AppImage"

# Windows (Git Bash / WSL)
# ORCA="/c/Program Files/OrcaSlicer/orca-slicer.exe"
```

Profiles ship with the app. On macOS the bundled system profiles are under:

```
~/Library/Application Support/OrcaSlicer/system/<Vendor>/machine/
~/Library/Application Support/OrcaSlicer/system/<Vendor>/filament/
```

You can point `--load-settings` / `--load-filaments` at those JSON files directly, or export your own from the GUI.

---

## (a) Headless slice — the basics

The minimal working command: give it a machine profile, a process profile, a filament profile, an output directory, and the STL. `--slice 1` tells it to actually slice (not just load).

```bash
ORCA="/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"
MACHINE="$HOME/Library/Application Support/OrcaSlicer/system/Vendor/machine/Generic 0.4 nozzle.json"
FILAMENT="$HOME/Library/Application Support/OrcaSlicer/system/Vendor/filament/Generic PLA.json"
PROCESS="./examples/process.json"
STL="./model.stl"
OUTDIR="./out"

"$ORCA" \
  --slice 1 \
  --load-settings "$MACHINE;$PROCESS" \
  --load-filaments "$FILAMENT" \
  --outputdir "$OUTDIR" \
  "$STL"
```

Key points:

- **`--load-settings` takes a semicolon-separated list**: `"machine.json;process.json"`. The machine profile goes **first**, the process profile **second**. (See [Fix 3](#fix-3--split-cleanraft-process-json--machineprocess-load-order).)
- **`--load-filaments`** is separate from `--load-settings`.
- Output is written as `plate_1.gcode` (and `plate_2.gcode`, … for multi-plate) inside `--outputdir`. Rename it afterwards if you want a meaningful filename:

```bash
mv "$OUTDIR/plate_1.gcode" "$OUTDIR/model.gcode"
```

---

## (b) Slicing with a raft

A raft is a detachable printed base under the whole model — handy for adhesion or for parts you want to pop off a solid platform. In OrcaSlicer CLI you enable it through **raft parameters in the process profile**, *not* through a special flag.

The safest approach is a **separate raft process JSON** (see [Fix 3](#fix-3--split-cleanraft-process-json--machineprocess-load-order)) so your clean profile stays clean:

```bash
"$ORCA" \
  --slice 1 \
  --load-settings "$MACHINE;./examples/process_raft.json" \
  --load-filaments "$FILAMENT" \
  --outputdir "$OUTDIR" \
  "$STL"
```

The raft-specific keys (all as **strings** — see [Fix 2](#fix-2--raft-parameters-must-be-strings)):

```json
{
  "raft_layers": "2",
  "raft_first_layer_density": "90%",
  "raft_contact_distance": "0.1"
}
```

- `raft_layers` — number of raft layers. `"2"` is a good detachable base.
- `raft_first_layer_density` — infill density of the raft's first layer, e.g. `"90%"`.
- `raft_contact_distance` — gap between raft top and model bottom (mm). Larger = easier to peel off, smaller = better surface. `"0.1"` is a typical starting point.

See [`examples/process_raft.json`](examples/process_raft.json) for a complete profile.

---

## (c) Multi-plate / auto-arrange

To slice several STLs onto a single plate, pass them all and add **`--arrange 1`** so OrcaSlicer auto-packs them on the bed:

```bash
"$ORCA" \
  --arrange 1 \
  --slice 1 \
  --load-settings "$MACHINE;$PROCESS" \
  --load-filaments "$FILAMENT" \
  --outputdir "$OUTDIR" \
  "$STL1" "$STL2" "$STL3"
```

- `--arrange 1` runs the nesting/arrangement pass so parts don't overlap. Without it, multiple objects can be stacked at the origin.
- Always check that your parts fit the bed (e.g. `< 220 mm` on a 220×220 bed) before slicing — the CLI will happily produce out-of-bounds gcode.
- If arrangement can't fit everything on one plate, OrcaSlicer spreads objects across multiple plates, producing `plate_1.gcode`, `plate_2.gcode`, etc.

---

## (d) The three fixes that cost hours

These are the non-obvious failures. Each one either errors cryptically or fails silently.

### Fix 1 — "Relative extruder addressing" error

**Symptom:** the CLI aborts with a *"Relative extruder addressing requires resetting the extruder position…"* style error, and no gcode is produced.

**Cause:** the machine/process expects the extruder position to be reset, but the layer-change hook doesn't emit a reset.

**Fix:** add an explicit extruder-position reset to the layer change gcode in your **process** profile:

```json
{
  "layer_change_gcode": "G92 E0\n"
}
```

`G92 E0` resets the extruder axis to zero at each layer change. The trailing `\n` matters — keep it. This single line makes the "Relative extruder addressing" error go away.

### Fix 2 — raft parameters must be STRINGS

**Symptom:** you add raft settings as JSON numbers and the slice fails to load the profile / throws a type error.

**Cause:** OrcaSlicer's profile schema expects these values as **strings**, even the numeric ones. Passing bare numbers breaks parsing.

**Wrong** (fails):

```json
{
  "raft_layers": 2,
  "raft_first_layer_density": 90,
  "raft_contact_distance": 0.1
}
```

**Right** (works):

```json
{
  "raft_layers": "2",
  "raft_first_layer_density": "90%",
  "raft_contact_distance": "0.1"
}
```

Note `raft_first_layer_density` even carries the literal `%` inside the string (`"90%"`). Treat *all* process-profile values as strings unless you've confirmed otherwise.

### Fix 3 — split clean/raft process JSON + `machine;process` load order

Two related habits that save headaches:

**1. Keep a clean process JSON and a separate raft process JSON.** Don't toggle raft settings in-place. Maintain two files:

- `process.json` — your normal, raft-free profile.
- `process_raft.json` — same profile + the three raft keys from Fix 2.

Then you just point `--load-settings` at whichever one you need. No risk of leaving raft settings on by accident, and diffs stay readable.

**2. Use the `machine;process` order inside `--load-settings`.** The value is a **semicolon-separated list**, machine first, process second:

```bash
--load-settings "machine.json;process.json"
```

Getting the order wrong (or forgetting the semicolon and passing two `--load-settings` flags) leads to settings not being applied. Machine-then-process in a single quoted, semicolon-joined argument is the reliable form.

---

## (e) Booleans on STL / lessons learned

Not strictly a slicer topic, but if you're generating STLs programmatically (Blender, trimesh, manifold3d, OpenSCAD) and feeding them to this pipeline, these bit us hard:

- **Boolean UNION / DIFFERENCE on already-"finished" closed meshes is high-risk.** Union of small plugs into a wall (to close holes) can fail *silently* — the solver returns "success" but the hole is still open. Both EXACT and MANIFOLD solvers exhibited this.
  - Things that *didn't* reliably work: cylindrical plugs, sphere plugs, `holes_fill`-type operations, voxel remesh (loses detail), corner-peg patches (leave visible protrusions).
  - **Pragmatic workaround:** leave the plug as an *overlapping shell* rather than forcing a watertight boolean. The **slicer fuses overlapping shells during slicing** and lays solid infill across the wall where the holes were — so the printed part comes out solid even though the STL isn't strictly manifold there.
- **Changing the wall thickness of a closed STL via booleans distorts the mesh.** Uniform displace, outer-only vertex groups, raycast classification, solidify+union, plug+inflate+recut — all produced artifacts. This is a job for **parametric CAD** (Fusion, Onshape, OpenSCAD), not mesh booleans.
- **Cutting features (feet, standoffs) with booleans** can fail or leave protrusions. Cutting a flat plane (e.g. everything below `Z < 5`) from the original mesh, then doing `DIFFERENCE` with clean primitives, is more robust than trying to boolean-edit the finished part in place.
- **Non-uniform scaling** (`X != Y == Z`) is fine when you need to hit two target dimensions at once while preserving a slope angle — keep the two axes that define the angle equal.

The meta-lesson: **decide whether a mesh boolean is even feasible before you spend an hour on it.** If the part is already a finished closed mesh, prefer regenerating from parametric source over editing the mesh.

---

## Files in this repo

| File | What it is |
|------|-----------|
| [`README.md`](README.md) | This cookbook |
| [`slice.sh`](slice.sh) | Example bash wrapper (edit the variables at the top) |
| [`examples/process.json`](examples/process.json) | Generic clean process profile |
| [`examples/process_raft.json`](examples/process_raft.json) | Generic process profile with a 2-layer raft |
| [`LICENSE`](LICENSE) | MIT |

---

## License

MIT — see [LICENSE](LICENSE). Contributions and additional recipes welcome.
