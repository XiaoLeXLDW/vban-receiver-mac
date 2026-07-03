# Changelog

## 0.3.12 - 2026-07-03

This version consolidates the UI/tray engineering log and the unreleased changelog into one release entry.

### Added

- Added a macOS menu bar status item as a companion control surface while keeping the app as a regular Dock app.
- Added status menu actions for showing or hiding the window, starting or stopping receiving, manual output repair, automatic output repair, opening the diagnostic log, and quitting.
- Added close-to-menu-bar behavior: closing the main window hides it instead of terminating the receiver.
- Added Dock reopen support so the window can be restored after being hidden.
- Added `make validate-app` to verify the packaged app plist, executable bit, code signature, and target architecture.
- Added build-time `ARCH`, `VERSION`, and `BUILD_NUMBER` overrides for local packaging.
- Added UDP receiver `localPort` exposure for dynamic-port tests and runtime introspection.
- Added tests for UDP stream/source filtering, receiver port lifecycle, strict VBAN payload validation, and reserved format-bit rejection.

### Changed

- Bumped the default packaged app version to `0.3.12` and build number to `16`.
- Refined the dashboard UI with tighter card/button corner radii, clearer panel accent bars, improved muted-text contrast, and hover feedback for custom buttons and dropdowns.
- Restored the manual repair control as a small `✨` button with subtler idle opacity, hover emphasis, and keyboard focus indication.
- Standardized manual repair menu labels as `✨ Repair Output` / `✨ 修复输出`.
- Improved running-state input fields so locked UDP/stream/source settings are visually distinct.
- Improved volume and meter interaction: the level meter is read-only, and volume changes only respond near the volume track.
- Added slider-style accessibility metadata and increment/decrement actions for the volume control.
- Guarded the Return/Enter receive shortcut so it does not fire while editing fields or operating other controls.
- Made port parsing strict instead of accepting partially numeric text.
- Tracked missing packet counters per stream identity rather than using one global frame counter.
- Moved diagnostic log writes onto a dedicated serial queue.
- Increased the UDP receive buffer size and hardened receiver shutdown paths.
- Packaging now honors injected version/build values and can skip redundant rebuilds when called from `make app`.

### Fixed

- Prevented app termination when the user closes the only window.
- Prevented accidental volume changes from clicks on the level meter.
- Prevented accidental start/stop toggles from Return while editing text fields.
- Rejected malformed VBAN packets with trailing payload bytes.
- Rejected VBAN packets that set reserved format bits.
- Avoided potential UDP receiver deadlock when stopping from its own dispatch queue.
- Handled dispatch source allocation failure during UDP receiver startup.

### Engineering Notes

- `Codebase Onboarding Engineer` reviewed the existing AppKit lifecycle, Dock menu, main menu, and safe shape for menu bar status item support.
- `UI Designer` reviewed the manual repair button direction and recommended keeping the compact `✨` affordance subtle rather than replacing it with a conventional tool icon.
- The menu bar item is intentionally a companion surface, not a replacement for the main window or Dock menu.
- Quitting still uses the existing termination path so the receiver stops and audio state is reset.

### Verified

- `make test`
- `make validate-app`
- Manual runtime smoke check: opened the packaged app, verified the `VBANReceiver` process started, then explicitly quit and verified the process exited.
