# Changelog

## 0.3.13 - 2026-07-24

### Added

- Added `make perf-idle`, a real-machine CPU gate with a 3-second warmup, 10 samples, a median below 1%, and rejection of three consecutive samples above 3%.
- Added bounded receiver-statistics and audio-ingress regression tests, including reordered frame counters, identity eviction, Float64 sanitization, and UDP backlog shutdown.
- Added read-only artifact validation, a strict Developer ID/Gatekeeper/notarization release gate, and a Git-tracked release-input check.
- Added focused activity-policy tests for packet freshness and level-meter animation lifecycle decisions.
- Added `CONTEXT.md` to define Stopped, Waiting, Receiving, Menu Bar Residency, and Presentation Suspended consistently.
- Added a pure output-recovery policy with captured-trace, timer re-arm, notification-storm, route, format, stall, and restoration tests.
- Added ADR 0001 to define state-diff-driven output recovery.
- Added the MIT License to the source repository and packaged app resources.

### Changed

- Replaced the always-running 30 Hz dashboard timer with an on-demand level animation timer that exists only while the receiver is running, the window is visible, and the meter is active.
- Replaced polling for the Receiving-to-Waiting transition with a monotonic, one-shot freshness timer while preserving the existing 2-second threshold.
- Suspended level calculation and all dashboard rendering while the window is hidden, minimized, fully occluded, or on another Space; UDP reception, audio playback, counters, and automatic output repair continue normally.
- Restored the latest in-memory dashboard snapshot when the window becomes visible again.
- Avoided repeated AppKit state, icon, font, and menu updates when the rendered receiver state has not changed.
- Coalesced CoreAudio output notifications after 200 ms of quiet, capped at one second, and evaluated the final effective output state before deciding whether playback needs recovery.
- Followed a real default-output route change with one controlled restart while ignoring nominal-rate, running, hog-mode, and same-route notifications when the queue remains healthy.
- Made Manual Repair reconnect the current effective output without silently enabling output-device locking.
- Preserved locked output identity by UID so a reattached device can be resolved even if CoreAudio assigns a new object ID.
- Gave each Audio Queue generation an independent callback context and rejected delayed callbacks from replaced queues.
- Separated persistent Output Unavailable errors from transient packet/audio errors; normal packets no longer clear an output fault.
- Rotated the diagnostic JSONL at 10 MB with two backups and a cross-process lock; failed rotation keeps the source log intact.
- Coalesced packet statistics into at most one pending main-thread refresh and capped tracked sender/stream identities.
- Bounded UDP drain work per dispatch-source callback and audio ingress to 256 pending tasks or 8 MiB.
- Limited audio queue reconfiguration attempts during hostile or unstable format oscillation, and coalesced audio callbacks before main-thread delivery.
- Refreshed the English and Chinese README screenshots and quick-start guides from the current app UI.
- Bumped the default packaged app version to `0.3.13` and build number to `17`.

### Fixed

- Fixed latency jumps and reset-count spikes caused by treating every CoreAudio property notification as an output failure.
- Fixed a potential Audio Queue callback race during stop/dispose and a possible `reset` self-deadlock on the audio serial queue.
- Fixed the 500 ms restoration deadline so a single packet below the start-buffer threshold cannot produce a false Output Unavailable alert.
- Fixed Manual Repair being treated as standalone evidence for repeated automatic queue rebuilds.
- Fixed hostname and equivalent IPv4/IPv6 source filters by resolving them once at receiver startup.
- Fixed late packets regressing the sequence watermark and permanently inflating the Missing counter.
- Fixed Float64 values overflowing to non-finite Float32 samples.
- Fixed stale receiver-session callbacks and successful network packets hiding persistent audio-output errors.
- Fixed `make validate-app` rebuilding and replacing the artifact it was supposed to validate.
- Fixed IPv6 link-local source filtering across interface scopes and bounded per-stream reorder bookkeeping.
- Fixed handler replacement races during stop, and made the next successful playback enqueue clear a transient audio error.
- Fixed rapid UDP stop/restart descriptor reuse by closing sockets from the dispatch-source cancel handler and waiting for cancellation off the receiver queue.
- Fixed false `Listening` state when another IPv4 UDP socket already owns the requested port; startup now fails with the bind error instead of sharing and losing traffic.
- Optically aligned the Chinese and English status-pill text with its indicator dot.
- Fixed failed CoreAudio listener removal leaving a callback context that could outlive the player.
- Fixed slow or transiently failed output restoration preventing later packet-driven retries while the intended device is available.
- Fixed release-tree validation so ignored files are skipped and unstaged release-input changes cannot differ from the prospective commit.

### Performance

- Reduced visible Stopped CPU from an observed median of approximately 16.2% to 0.000% in the 10-sample idle gate.
- Verified Waiting on an unused UDP port at 0.0% across all 10 samples.

### Verified

- `make test`
- `make perf-idle`
- `make validate-app`
- The custom-version artifact hash remaining unchanged across `make validate-app`.
- ASan/UBSan and TSan runs for all six test binaries.
- Synthetic VBAN receive, the 2-second Receiving-to-Waiting transition, and hidden-window receive/snapshot restoration.
- A 50-notification same-state storm with zero restarts.
- A silent real-device route switch from Built-in Speaker to BlackHole and back, with exactly one restart per switch and the original route restored.
- AddressSanitizer and ThreadSanitizer silent-receive probes.
- 10 MB active plus two-backup log rotation and a forced copy-failure preservation path.
- A 15-minute 48 kHz silent receive soak with 168,751 packets sent/received, zero errors, zero resets, and zero buffer-pressure events.

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
