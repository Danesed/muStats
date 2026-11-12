# Changelog

Each release has up to three groups: New, Improved and Fixed. `Scripts/appcast.py` reads
this file, so the update window and this page always say the same thing. Keep the
headings exactly as they are below.

## 0.2.1

### New

- A new app icon: a serif μ with the status dot, on the chip's floorplan drawn as a load
  map, where a darker cell is a busier one.

## 0.2.0

### New

- Chip view redrawn as the real package: the die with its cores, the GPU and the memory
  modules beside it. Each core glows with its own load, the memory cells fill with app,
  wired and compressed memory, and the die warms with the processor's temperature.
- This Mac's usual: charts show the range this Mac normally sits in at this hour, learnt
  from its own 30 days of history. The status line adds "usually 23%" beside a reading.
- Apps, not processes: the Top Processes module and the lists in CPU, Memory and Battery
  show one row per app with all of its helpers added up, with CPU, memory and energy
  side by side. Click a column to rank by it.
- Since you last looked: when the Mac is calm now, the status line says what happened
  while the panel was closed, for example "CPU peaked at 91% at 14:20, Xcode".
- The panel opens on the module that needs attention, and folds it again when it closes.
- Calm rows step back when another row needs attention.
- Disk forecast: "Disk full in about 12 days" when the startup disk keeps filling.
- Before and after a macOS update: the System module compares a typical hour of the week
  before the update with the days since.
- One download for Apple silicon and Intel Macs.
- Optional gauges under the module rows (Settings > Panel).

### Improved

- The network reads addresses and routes only when macOS reports a change.
- An hour of history is built from that hour, not from the whole day.
- Tests now fail when a hot path costs more than its budget.

## 0.1.1

### Fixed

- `mustats version` reports the real version when run through the Homebrew link.
- The D-S-K caption beside the disk bar is aligned on one left edge.

## 0.1.0

### New

- Activity rings in the menu bar, up to three, with six colour sets or your own colours.
- Rings and text readouts side by side, for example rings for CPU, memory and disk with
  temperature and network as text.
- A summary line that names what is wrong and which process is causing it.
- Today view: the last 24 hours of CPU with the notable moments marked.
- Chip view: a live floor plan of the cores, GPU and memory.
- Desktop widgets, Rings and Overview, in small, medium and large, set up from the app.
- Smart alerts for CPU, memory pressure, temperature, battery and disk.
- Per-process energy, and a `mustats` command-line tool.
- Update notice at the top of the panel, with Install and Skip, and a badge on the
  Settings button while an update is waiting.
- Settings > Panel: choose when the status line shows, which modules appear, and every
  part of their details. Hidden parts are not read.
