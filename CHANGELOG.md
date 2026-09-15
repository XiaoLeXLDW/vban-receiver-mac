# Changelog

## Unreleased

- Show “Starting / 正在启动” in the status pill while the source hostname is being resolved, without changing the existing Waiting labels.
- Mark development packages with their architecture and source commit, and include build provenance in the app and About dialog.

- Resolve source hostnames in the background with a five-second startup timeout. Stopping or restarting reception discards stale lookup results.
- Display IPv6 sender endpoints with brackets so the address and port are unambiguous.
- Put download and installation instructions first in both languages, and clarify menu-bar behavior, counters, diagnostics privacy and signature status.
- Add automated source, documentation and community-package checks, with shared version defaults and ZIP/checksum verification.

## 0.3.13 - 2026-07-24

### Improved

- Reduced unnecessary CPU use while stopped, waiting, or with the window hidden. Audio reception and playback continue when the window is hidden.
- Improved default-output switching and manual/automatic repair, avoiding interruptions from harmless CoreAudio notifications.
- Preserved locked output devices across disconnection and reconnection, and improved output-unavailable reporting and recovery retries.
- Bounded UDP processing, audio ingress and statistics bookkeeping to improve behavior under bursty or malformed traffic.
- Rotated diagnostic logs with bounded backups and protected the original log when rotation fails.
- Updated Chinese and English screenshots and added the MIT License to the app bundle.

### Fixed

- Fixed Audio Queue callback lifetime and receiver stop/restart races.
- Fixed hostname and equivalent IPv4/IPv6 source filtering, including scoped IPv6 link-local addresses.
- Fixed late packets permanently inflating the Missing counter and invalid Float64 conversions.
- Fixed stale callbacks or successful network packets hiding an output fault.
- Fixed misleading listening status when the requested UDP port is already occupied.
- Fixed artifact validation rebuilding the app it was meant to inspect.

Historical implementation and local validation evidence is recorded in the
[idle CPU record](docs/engineering-logs/2026-07-22-idle-cpu.md) and
[output recovery record](docs/engineering-logs/2026-07-23-output-recovery.md).
Performance measurements describe the recorded test environment, not a CPU guarantee for every Mac.

## 0.3.12 - 2026-07-03

### Added

- Added a menu bar icon with window, reception, output repair, diagnostic log and quit actions.
- Closing the main window now hides it while reception continues. Clicking the Dock icon restores it.
- Added app validation and configurable architecture, version and build number when building from source.

### Improved

- Refined dashboard spacing, contrast, hover feedback and keyboard focus.
- Kept the compact `✨` manual output repair button and consistent repair menu labels.
- Made locked reception settings clearer and improved volume accessibility.
- Tracked missing packets separately for each stream and moved diagnostic writes off the UI thread.

### Fixed

- Prevented accidental volume changes from clicks on the read-only level meter.
- Prevented Return/Enter toggling reception while editing text or operating another control.
- Rejected partially numeric ports, malformed payload lengths and reserved VBAN format bits.
- Improved receiver shutdown and dispatch-source allocation failure handling.
