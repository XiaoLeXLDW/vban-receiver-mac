# VBAN Receiver

This context defines the runtime states of the VBAN audio receiver and the language used when discussing idle behavior.

## Language

**Idle State**:
A runtime state in which no matching VBAN audio is currently being received. It includes both Stopped and Waiting.
_Avoid_: Not receiving, inactive

**Stopped**:
The receiver is not listening for VBAN packets and no audio is being played.
_Avoid_: Waiting, idle receiver

**Waiting**:
The receiver is listening for matching VBAN packets, but none have arrived recently.
_Avoid_: Stopped, receiving

**Receiving**:
The receiver is listening and has received matching VBAN audio recently.
_Avoid_: Listening

**Menu Bar Residency**:
The app remains running and accessible from the macOS menu bar while its main window is hidden.
_Avoid_: Tray mode, minimized, closed

**Presentation Suspended**:
The main window is not currently visible, while packet reception, audio playback, and output recovery continue normally. Visual level reporting resumes when the window becomes visible again.
_Avoid_: Paused, stopped, background receiving

**Output Route Change**:
The identity of the effective macOS output device changes. When output-device locking is disabled, the receiver follows the new route with one controlled playback restart.
_Avoid_: Output notification, device activity

**Incidental Output Notification**:
A CoreAudio device-property notification that does not change the effective output-device identity. It is not an Output Route Change and does not justify interrupting healthy playback.
_Avoid_: Output failure, route change

**Output Format Change**:
The current output device can no longer continue the active playback format, such as when its output stream becomes unavailable. A nominal hardware sample-rate change alone does not qualify while the audio queue remains healthy, because Audio Queue Services can perform format conversion. Repeated notifications without a demonstrated compatibility failure are incidental.
_Avoid_: Sample-rate notification, configuration callback

**Playback Stall**:
The audio queue reports that it is not running while it still owns pending audio and fresh VBAN packets continue to arrive. This is a playback failure that requires recovery, not merely an output notification.
_Avoid_: Queue notification, temporary silence, waiting

**Locked Output Route**:
An output route whose device identity must remain stable even when the macOS default output changes. If that device is unavailable, playback waits for the same device to return instead of falling back to another output.
_Avoid_: Preferred output, current default output

**Buffer Drift**:
A sustained change in queued audio duration while VBAN input remains continuous, typically caused by clock-rate mismatch or arrival pacing. It is distinct from a sudden latency change caused by restarting playback.
_Avoid_: Output recovery, notification storm, network delay

**Automatic Output Repair**:
An explicitly enabled recovery policy for a validated playback failure or sustained queue lag. Incidental output notifications do not qualify as repair conditions.
_Avoid_: Automatic route following, notification handling

**Controlled Playback Restart**:
A single intentional interruption that replaces the active playback queue after a validated Output Route Change, Output Format Change, Playback Stall, or Automatic Output Repair condition. It counts as an output reset but is not inherently an error.
_Avoid_: Refresh, notification response, repeated recovery

**Output Stabilization Window**:
A brief period during which related route and format notifications are treated as one possible change. Playback continues on the existing queue, and only the final effective output state is evaluated.
_Avoid_: Recovery delay, notification cooldown

**Output Unavailable**:
The intended output device cannot currently accept playback. VBAN reception continues and retains its own Receiving or Waiting state while the output problem is reported separately.
_Avoid_: Stopped, Waiting, network failure

**Output Restored**:
The intended output device is available and the current-generation audio queue has confirmed that playback is running on that device UID. Device discovery alone does not establish restoration.
_Avoid_: Device detected, restart requested

**Output Availability Alert**:
A persistent user-facing indication that the intended output is unavailable. It takes precedence over transient packet or audio errors and is cleared only by Output Restored.
_Avoid_: Packet error, temporary notification, receiver state

**Manual Output Repair**:
An explicit request to reconnect playback to the currently effective output route. It does not change route-following or output-locking policy.
_Avoid_: Lock output, select output, automatic repair
