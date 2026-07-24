# State-Diff Output Recovery and Diagnostic Log Rotation

Date: 2026-07-23
Status: Implemented and verified locally

## Goal

Remove latency jumps caused by false CoreAudio recovery while preserving real route following, explicit Automatic Output Repair, manual recovery, network reception, and existing latency-profile behavior. Bound diagnostic disk use without losing the pre-rotation evidence file.

## Live Diagnosis

The active diagnostic log had grown to 56,966,943 bytes. Recent examples showed:

- a healthy queue with about 56 ms buffered, followed by a generic output notification and recovery roughly 8 ms later;
- a healthy queue with about 34 ms buffered, followed by the same pattern roughly 9 ms later;
- five generic output-configuration events and two recoveries in a recent 53-minute window, with no concurrent buffer-pressure event.

A deterministic replay found 21 historical examples where queues with roughly 34-112 ms buffered were rebuilt immediately after generic notifications. The root cause was notification-driven recovery: callback selectors and object IDs were discarded, and every callback unconditionally tore down the Audio Queue.

## Runtime Contract

- Incidental same-route notifications never interrupt a healthy queue.
- Default-output UID changes follow the new route with one controlled restart.
- Nominal sample-rate changes alone do not restart a healthy queue; Audio Queue conversion remains active.
- A playback stall requires a started queue, known `IsRunning == false`, pending frames, and fresh input.
- The `IsRunning` listener provides immediate stall detection; the one-second watchdog is the fallback.
- A locked route waits for the same UID to return and never falls back to another device.
- Manual Repair reconnects the current effective route without changing route-following or lock policy.
- Output Unavailable is separate from Receiving/Waiting and has priority over transient packet/audio errors.
- Output Restored requires a current-generation queue confirmed running on the intended available UID.

These terms are recorded in `CONTEXT.md`; the architectural choice is recorded in `docs/adr/0001-state-diff-driven-output-recovery.md`.

## Implementation

1. Added a pure output-recovery policy for notification deadlines, timer re-arm decisions, state-diff decisions, stall predicates, and alert-clear predicates.
2. Preserved CoreAudio object IDs and selectors, coalesced bursts after 200 ms of quiet, capped bursts at one second, and re-armed early timer deliveries.
3. Replaced generic notification teardown with a stabilized comparison of intended UID, queue baseline UID, output channels, availability, running state, pending frames, and packet freshness.
4. Added per-generation callback contexts for CoreAudio and Audio Queue callbacks. Queue teardown invalidates shared state under the same synchronization boundary before `Stop` and `Dispose`.
5. Added queue-specific reset protection and diagnostic-queue draining so reset cannot self-deadlock and termination snapshots reach disk.
6. Stored locked output identity by UID and re-resolved its current `AudioObjectID` after device-list changes.
7. Added a persistent output-availability error channel in AppDelegate. Normal packets clear only transient errors.
8. Removed the hidden `locksOutputDevice = YES` side effect from Manual Repair.
9. Rotated diagnostics at 10 MB with two backups, serialized across processes with a lock file, and retained the original log if tail-copy or rotation fails.
10. Added `VBAN_DIAGNOSTIC_LOG_PATH` as an isolated runtime-test hook for destructive rotation tests.
11. Bounded cross-process lock acquisition to 100 ms per diagnostic line so a stalled peer cannot block reset or app termination indefinitely.
12. Used monotonic uptime for packet freshness, notification stabilization, recovery cooldowns, and watchdog decisions.

## Pre-Rotation Archive

With no `VBANReceiver` process running, the old log was compressed to:

```text
~/Library/Logs/VBAN Receiver/diagnostics-2026-07-23-pre-rotation.jsonl.gz
```

`gzip -t` passed before the 56,966,943-byte active file was truncated. The verified archive is 658,972 bytes.

## Verification

- `make test`: packet, UDP, activity-policy, and output-recovery-policy suites passed.
- `make validate-app`: plist, executable, strict signature, and arm64 checks passed.
- `make perf-idle`: ten samples at 0.0%, median 0.000%.
- Same-state storm: 50 notifications, one coalesced `none` decision, zero restarts.
- Real route switch: Built-in Speaker to BlackHole to Built-in Speaker; exactly one controlled restart per switch, 3,761 packets sent/received, zero errors, original route restored.
- AddressSanitizer: final three-second silent receive, 569/569 packets, zero errors or resets.
- ThreadSanitizer: final three-second silent receive, 571/571 packets, zero reported races, errors, or resets.
- Log rotation: active plus `.1` and `.2` remained at or below 10 MB with complete JSONL boundaries.
- Log failure path: a forced tail-copy failure preserved the 11,900,000-byte source log and appended new diagnostics without deleting the original.
- Log lock contention: a peer held the lock for five seconds; the one-second runtime probe still reset and exited in 1.78 seconds instead of waiting for the peer.
- Fifteen-minute silent receive soak: 168,751 packets sent and received, zero errors, zero queue resets, zero buffer-pressure events, and a final healthy 48 ms queue on `BuiltInSpeakerDevice`.

## Remaining Scope

Adaptive resampling, jitter buffering, and active frame dropping remain outside this change unless post-fix evidence demonstrates Buffer Drift.
