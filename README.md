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

## Installation
- Download from Releases: https://github.com/aravhawk/lite-stats/releases
- Move `Lite Stats.app` to `/Applications`

## Development
- Open `Stats.xcodeproj` in Xcode 15+
- Build the `Stats` scheme (arm64 only)

## Localization
Supported locales (from `Stats/Supporting Files/*.lproj`):
`ar, bg, ca, cs, da, de, el, en, en-AU, en-GB, es, et, fa, fi, fr, he, hi, hr, hu, id, it, ja, ko, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sl, sv, th, tr, uk, vi, zh-Hans, zh-Hant`

## License
MIT. See `LICENSE`.
