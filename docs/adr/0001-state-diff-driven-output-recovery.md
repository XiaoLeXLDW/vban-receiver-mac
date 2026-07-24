# ADR 0001: State-Diff-Driven Output Recovery

Date: 2026-07-23
Status: Accepted

## Context

CoreAudio can emit nominal-rate, stream-configuration, running, alive, and hog-mode notifications while an Audio Queue remains healthy. The previous implementation treated every notification as a playback failure and immediately disposed the queue. Live diagnostics showed healthy queues with 34-112 ms buffered being rebuilt within milliseconds of generic notifications, producing audible latency jumps and reset-count noise.

Audio Queue Services can perform format conversion, so a nominal hardware sample-rate notification alone does not prove that the active queue is incompatible with the output device. See [Apple Audio Queue Services](https://developer.apple.com/documentation/audiotoolbox/audio-queue-services).

## Decision

CoreAudio notifications are hints to re-read output state, not recovery commands.

1. Coalesce related notifications after 200 ms of quiet, with a maximum one-second burst window.
2. Compare the stabilized output state with the queue baseline: target UID, output-channel count, availability, queue generation, running state, pending frames, and fresh input.
3. Keep a healthy queue running when the target UID and compatible channel count are unchanged.
4. Perform exactly one controlled restart for a real route change, incompatible output channel count, or validated playback stall.
5. Treat a stall as a queue that was started, is known not to be running, still has pending frames, and has received fresh VBAN input within two seconds.
6. Keep Automatic Output Repair as a separate, explicitly enabled policy for sustained queue lag or a device that remains not running.
7. When an intended output is unavailable, continue network reception, do not fall back from a locked route, and clear the alert only after a current-generation queue is running on the intended UID.

Each Audio Queue generation owns a distinct callback context. Teardown invalidates the generation before stopping and disposing the queue, so delayed callbacks cannot mutate a replacement queue.

## Consequences

- Incidental notifications no longer interrupt playback.
- A real route change is evaluated after 200 ms of notification quiet, with continuing notification bursts capped at one second from the first event.
- Output recovery becomes observable through coalesced decision events instead of a full diagnostic snapshot for every notification.
- Clock drift and sustained queue growth remain separate work; this decision does not add adaptive resampling, a jitter buffer, or active frame dropping.

## Verification

- A 50-notification same-state storm produces one `none` decision and zero restarts.
- Built-in output to BlackHole and back produces exactly one `restart-route-change` decision per switch.
- Captured healthy-queue failure traces replay as `none`.
- Stall predicates and output-restoration predicates are covered by pure policy tests.
