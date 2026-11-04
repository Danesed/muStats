# Contributing

μStats has a few opinions. They are here so a pull request does not have to find them
in review.

## Getting set up

You need Xcode 26 or later: the panel uses Liquid Glass from the macOS 26 SDK. The app
itself runs on macOS 14 and later.

```sh
git clone <your fork>
cd muStats
swift build
swift test
Scripts/build.sh          # debug .app bundle
Scripts/build.sh release  # optimised .app bundle
```

To run your build, quit the running copy, replace `/Applications/muStats.app` with the
one the script prints, and launch it.

## Before you open a pull request

Run these:

```sh
swift build
swift test
.build/debug/muStats --probe            # sanity check the collectors on your Mac
.build/debug/muStats --render           # PNGs of every surface, in ./render
```

If you touched anything that draws, attach the relevant render. If you touched a
collector, say what you diffed its output against.

`--probe` prints raw collector output, so you can check it against `top`, `vm_stat`,
`netstat -ib`, `ioreg` and `pmset`. `--render` draws the menu bar, panel, desktop widget and
settings from fixture data at both appearances and both backing scales. Neither needs a
screen. `NSVisualEffectView` renders nothing offscreen, though, so a render shows layout
and SwiftUI drawing only: materials and translucency can only be judged on screen.

The fan minimum-RPM contract test can fail for a second while a fan spins down, so
re-run before you investigate. `swift build` sometimes reports success while linking
stale objects, so if an edit does not reach the binary, delete `.build` and build
again.

## House rules

**Never show a number the machine did not report.** A missing sensor renders as a dash
and an unsupported metric is greyed out with the reason attached. Never substitute a
zero, a guess or a last-known value. A sparkline with fewer than two samples draws
nothing, since a flat line reads as a metric pinned at zero.

**Comments explain why, not what.** A comment earns its place by recording the
measurement, the platform bug or the rejected alternative behind the code. If you removed
a comment's reason, remove the comment.

**Keep MuStatsKit free of UI.** It imports Foundation, IOKit and the rest of the system,
never SwiftUI or AppKit. The tests and `--probe` run in a windowless process.

**Match the design system.** Spacing, type and colour come from `Design` in
`Sources/MuStatsUI/Design/DesignSystem.swift`. Add a token there rather than a literal at
the call site.

## Source layout

| Path | What lives there |
| --- | --- |
| `Sources/MuStatsKit` | Collectors, the sampling engine, settings, formatting. No UI. |
| `Sources/MuStatsUI` | Menu bar drawing, panel, settings window, charts, design system. |
| `Sources/MuStatsWidgets` | The desktop widgets, a sandboxed extension. |
| `Sources/MuStats` | The executable, app delegate, the CLI and the probe and render commands. |
| `Tests/MuStatsKitTests` | Contract tests for the collectors, plus settings, panel and formatting. |
| `Scripts/build.sh` | Builds the binary and assembles the `.app`. |
| `Scripts/release.sh` | Signs, notarizes and packages the `.dmg`. See [docs/RELEASING.md](docs/RELEASING.md). |

## Screenshots

`docs/screenshots` holds the README images. They are real windows running on fixture
data, so they show no one's actual processes:

```sh
MUSTATS_DEMO=nominal MUSTATS_DEMO_OPEN=panel \
  .build/out/Products/Release/muStats.app/Contents/MacOS/muStats
```

`MUSTATS_DEMO` takes a scenario (`nominal`, `underLoad`, `charging`, `charged`,
`degraded`, `pending`). `MUSTATS_DEMO_OPEN` takes `panel`, `settings` or a module to open
expanded (`cpu`, `memory`, …), `MUSTATS_DEMO_SETTINGS` a `settings.json` to start
from, and `MUSTATS_DEMO_UPDATE` a version to show as an available update. A demo keeps its settings in a temporary folder and samples, alerts and updates
nothing. Quit the installed copy first, so only one status item is on screen.

## Commits

One change per commit. Conventional Commits, on one line:

```
feat: colour menu bar readouts from the metric palette
fix: keep the panel on screen when the status item is hidden
perf: draw charts as shapes instead of Canvas
```

## Reporting a bug

Include your Mac model, your macOS version, and the output of `muStats --probe` for the
metric that misbehaved. Sensor coverage varies across Macs more than anything else here,
so that output is often the whole report.
