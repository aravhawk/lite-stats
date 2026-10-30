# Lite Stats

Lite Stats is a trimmed, Apple Silicon-only fork of https://github.com/exelban/stats focused on low-overhead system monitoring from the macOS menu bar.

## Requirements
- macOS 13 or later
- Apple Silicon (arm64) only

## Modules
- CPU
- GPU (Apple AGX)
- RAM
- Disk
- Sensors (temperature, voltage, power, fans - read-only)

## Architecture
- `Stats`: menu bar app, settings UI, module orchestration
- `Kit`: shared UI components, widgets, UserDefaults-backed persistence
- `Modules/*`: feature frameworks (CPU/GPU/RAM/Disk/Sensors)
- `SMC`: read-only SMC reader used by the Sensors module
- `LaunchAtLogin`: login item using `SMAppService`
- No privileged helper or fan control components

## Efficiency model
- Readers are driven from the main thread: one phase-aligned timer per interval (`Kit/plugins/Repeater.swift`), so all modules sharing an interval read and redraw in a single wakeup. Readers that can block (disk, processes) set `blocking` and run on one background queue.
- Popup readers (processes, frequency, temperature, disk activity) only run while their popup or the combined popup is visible.
- Widgets only redraw when the displayed value changes (integer percent, device pixel, or a flat chart history).
- Views that are rarely seen (popup process lists, per-sensor rows, portals, notification settings) are built the first time they are displayed.
- Nothing is persisted on a timer; settings changes bump `Store.generation`, which hot paths use to cache derived values.

## Installation
- Download from Releases: https://github.com/aravhawk/lite-stats/releases
- Move `Lite Stats.app` to `/Applications`

## Development
- Open `Stats.xcodeproj` in Xcode 16.3 or later
- Build and run the `Lite Stats` scheme (arm64 only)
- `make build` archives, notarizes, staples and packages a DMG (expects a `AC_PASSWORD` notarytool keychain profile)
- `python3 Kit/scripts/i18n.py` checks that all localizations have the same keys

## Localization
Supported locales (from `Stats/Supporting Files/*.lproj`):
`ar, bg, ca, cs, da, de, el, en, en-AU, en-GB, es, et, fa, fi, fr, he, hi, hr, hu, id, it, ja, ko, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sl, sv, th, tr, uk, vi, zh-Hans, zh-Hant`

## License
MIT. See `LICENSE`.
