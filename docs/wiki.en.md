# VBAN Receiver Wiki

<p align="center">
  <a href="wiki.md">中文 Wiki</a>
</p>

This wiki documents every area, button, field, status, menu item, and common troubleshooting path in VBAN Receiver.

![VBAN Receiver quick start](assets/vban-receiver-usage-guide-en.png)

## How It Works

VBAN Receiver listens on a UDP port, parses VBAN AUDIO packets from VoiceMeeter, converts supported PCM samples into CoreAudio-friendly 32-bit float audio, and plays the stream through the current default macOS output device.

The receiver uses an IPv6 UDP socket with `IPV6_V6ONLY` disabled, so the same listener can receive IPv6 and IPv4-mapped traffic. The `Source` filter matches the sender host exactly and does not include the sender port.

## Main Window Overview

The window is fixed at `600 x 400` and is not resizable. It is split into these areas:

- Header: app title, language switch, and receiver status.
- Input: UDP port, stream filter, source filter, and start/stop control.
- Current Stream: current stream name, sender, and audio format.
- Audio Output: volume, level meter, latency profile, mute, automatic repair, manual repair, and reset count.
- Network Status: data, missing packets, filtered packets, errors, queue status, and quality summary.

## Header

### App Title

Shows `VBAN Receiver` or `VBAN 接收器`, depending on the selected language.

### Language Button

- In English, the button shows `中`; clicking it switches to Chinese.
- In Chinese, the button shows `EN`; clicking it switches to English.
- Switching languages does not stop the receiver or reset counters.

### Status Pill

The status pill in the top-right corner includes a color dot and status text:

- `Stopped / 未接收`: the app is not listening on the UDP port.
- `Waiting / 等待中`: the app is listening, but no valid audio packet arrived in the last 2 seconds.
- `Receiving / 接收中`: at least one valid audio packet arrived in the last 2 seconds.

The dot is gray when stopped, yellow while waiting, and green while receiving.

## Input Area

### UDP Port

The default port is `6980`. On start, the value must be in the `1-65535` range.

If the port cannot be bound because it is already used, unavailable, or blocked by the system, the error appears in the Network Status area.

### Stream

Filters by VBAN stream name.

- Empty: accept any VBAN audio stream.
- Filled: accept only packets whose stream name exactly matches this value.
- Non-matching packets are counted under `Filtered`.

### Source

Filters by sender host.

- Empty: accept any sender.
- Filled: accept only packets from the exact host/IP.
- IPv4-mapped IPv6 addresses are displayed as normal IPv4 addresses, for example `192.168.1.20`.
- Do not include the port. The Current Stream area may show `host:port`, but filtering uses only the host.

### Start Receiving

When clicked:

- Runtime counters are reset.
- Port, Stream, and Source fields become read-only while running.
- The current latency profile is applied to the audio buffering policy.
- The UDP socket starts listening.
- The button changes to `Stop Receiving`.

### Stop Receiving

The same button stops the receiver while it is running. When clicked:

- The UDP receiver stops.
- A diagnostic snapshot is written.
- The CoreAudio output queue is reset.
- The level meter clears.
- Port, Stream, and Source fields become editable again.

### Keyboard Start/Stop

When the window is focused, `Return` or `Enter` toggles start/stop. Shortcuts using `Command`, `Control`, or `Option` are ignored by this toggle.

## Current Stream Area

### Stream

Shows the stream name from the latest accepted VBAN packet. If the packet has no name, it shows `(unnamed) / （未命名）`.

### Source

Shows the sender of the latest accepted packet, usually as `IP:port`.

### Format

Shows the current audio format, including sample rate, data type, and channel count. Before a valid packet arrives, it shows `No signal / 无信号`.

The format text is compacted to fit the window. For example, `48000 Hz` may display as `48k`.

## Audio Output Area

### Volume

Displays the app output volume from `0%` to `100%`.

Controls:

- Click or drag the volume track.
- When the level/volume control has focus, use arrow keys.
- Arrow keys change volume by about `5%`.
- `Shift` + arrow keys change volume by about `1%`.
- `Home` sets volume to `0%`; `End` sets volume to `100%`.

This controls only the app's output volume. It does not change the system volume.

### Level

The level meter shows audio level on a `-48 dB` to `0 dB` scale.

- Input and output level can differ when the volume is below `100%`.
- When muted, output level is treated as `0`.
- The visual meter is smoothed to avoid excessive jitter.

### Latency

The latency menu controls playback buffering. Faster profiles reduce latency but are more sensitive to Wi-Fi jitter. Slower profiles buffer more audio and are more stable.

| Profile | Max Queued Duration | Max Buffers | Start Buffers | Recommended Use |
|---|---:|---:|---:|---|
| `Fast / 快速` | 0.30 s | 192 | 2 | Lowest latency on stable wired LAN |
| `Optimal / 最佳` | 0.60 s | 384 | 2 | Default balance of latency and stability |
| `Medium / 中等` | 0.90 s | 512 | 2 | Normal Wi-Fi or light jitter |
| `Slow / 慢速` | 1.80 s | 1024 | 4 | Unstable Wi-Fi or bursty sender |
| `Very Slow / 非常慢` | 3.00 s | 2048 | 6 | Maximum stability, higher latency |

Changing the latency profile writes a diagnostic snapshot. It does not stop UDP receiving.

### Auto

Automatic repair is off by default. When enabled, the app tries to reconnect output if it detects a stuck output queue, CoreAudio output state anomaly, or output device change.

Use it when:

- Audio disappears after switching Bluetooth headphones or external sound cards.
- The system default output device changes.
- The audio queue reports that it is running, but output is not behaving normally.

### Sparkle Repair Button

The button is shown as `✨`. While running, clicking it:

- Locks the current default output device policy.
- Reconnects CoreAudio output.
- Resets audio output and the buffer queue.
- Writes a diagnostic snapshot.
- Increments the `Reset` count.

Use it when packets are arriving but no sound is heard.

### Mute

Mute affects only this app's output. It does not stop receiving, clear buffers, or change system volume.

When muted:

- CoreAudio output volume is set to `0`.
- The volume slider keeps its previous value.
- Unmuting restores the previous output volume.

### Reset

Shows the number of output queue resets. This can increase because of:

- Manual repair.
- Buffer pressure causing queued audio to be dropped/reset.
- Output queue recovery.

If this count keeps increasing, the likely cause is network jitter, bursty sending, output device changes, or a latency profile that is too aggressive.

## Network Status Area

### Data

Number of valid VBAN AUDIO packets accepted after filters.

### Missing

Estimated missing packet count based on VBAN frame counters.

If the received frame counter skips the expected value, Missing increases. Very large unexpected gaps are counted conservatively to avoid runaway counters from bad data.

### Filtered

Packets rejected because `Stream` or `Source` did not match.

If `Filtered` grows but `Data` does not:

- Check whether the VoiceMeeter stream name exactly matches the app value.
- Make sure `Source` contains only the host/IP and no port.
- Check whether the sender IP changed.

### Errors

Invalid VBAN packets, UDP receive errors, parse errors, and audio output errors increment this counter and show an error message.

Common causes:

- The UDP port cannot be bound.
- Data on the port is not valid VBAN AUDIO.
- The audio format cannot be decoded.
- CoreAudio cannot create or enqueue output buffers.

### Queue

The lower queue text currently shows `Queue: 0 / 队列：0`. Output queue reset count is shown in the Audio Output area as `Reset`.

### Normal / Check

Network quality summary:

- `Normal / 正常`: no missing packets and no errors.
- `Check / 需留意`: missing packets or errors have been observed.

## Menu Items

### About VBAN Receiver

Shows version, build number, and credits.

### Write Diagnostic Snapshot

Writes the current audio output, queue, device, and state snapshot to the diagnostic log.

### Open Diagnostic Log

Opens the diagnostic log location:

```text
~/Library/Logs/VBAN Receiver/diagnostics.jsonl
```

The log uses JSON Lines. Each line is one event or snapshot.

### Repair Output

The menu item is equivalent to the `✨` manual repair button. The shortcut is `Command + R`.

### Dock Menu

The Dock menu provides:

- `Start Receiving / Stop Receiving`
- `Repair Output`

## Supported Audio

VBAN Receiver supports VBAN AUDIO over UDP with these PCM sample types:

- unsigned 8-bit
- signed 16-bit
- signed 24-bit
- signed 32-bit
- 32-bit float
- 64-bit float

Internally, samples are converted to 32-bit float for CoreAudio output. Sample rate and channel count are read from VBAN packets. If the format changes, the output queue is rebuilt.

Unsupported:

- Compressed VBAN codecs.
- VBAN serial/text and other non-audio subprotocols.

## Common Scenarios

### No Sound

1. Check whether the status is `Receiving / 接收中`.
2. Check whether `Data` is increasing.
3. Confirm the macOS default output device.
4. Confirm `Mute` is not enabled.
5. Click `✨` to manually repair output.
6. If it happens often, enable `Auto`.

### Stuck on Waiting

1. Confirm the outgoing stream is enabled in VoiceMeeter.
2. Confirm the target IP is this Mac's LAN IP.
3. Confirm the port matches the app, usually `6980`.
4. Temporarily clear `Stream` and `Source`.
5. Check whether a firewall is blocking UDP.

### Filtered Keeps Increasing

The app is receiving UDP/VBAN traffic, but filters do not match.

Try:

- Clear `Stream`.
- Clear `Source`.
- Compare the sender shown in Current Stream before setting a source filter.

### Missing Keeps Increasing

Frame counters have gaps, usually because of packet loss or sender bursts.

Try:

- Prefer wired networking.
- Change latency to `Medium`, `Slow`, or `Very Slow`.
- Reduce sender load or avoid Wi-Fi roaming.

### Errors Keep Increasing

The app is seeing invalid data, unsupported format, or CoreAudio errors.

Try:

- Confirm VoiceMeeter is sending PCM VBAN AUDIO.
- Avoid sending serial/text VBAN streams to the same port.
- Open the diagnostic log and inspect recent events.

## Distribution

`make app` creates an app bundle with ad-hoc signing for local testing. Public distribution to other Macs should use Developer ID signing and notarization.
