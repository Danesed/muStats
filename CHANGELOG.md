# Changelog

Each release has up to three groups: New, Improved and Fixed. `Scripts/appcast.py` reads
this file, so the update window and this page always say the same thing. Keep the
headings exactly as they are below.

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
