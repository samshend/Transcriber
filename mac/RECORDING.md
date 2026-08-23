# Recording reliability & speaker attribution

_Written 2026-07-30 after a real 1:07 session lost one side of the conversation._

## 1. The incident

A 1:07:06 recording (mic + system audio, online session) came back with the user's own side
missing from ~38 min onwards, and with several speaker labels swapped.

### Evidence gathered

| Check | Result |
|---|---|
| Transcript timeline | The user's last turn is at **38:11**. From there to 1:03:48 only the other speaker appears (141 blocks vs 122). |
| Per-5-min word counts | The user's share decays: 2 894 chars (25–30 min) → 1 042 (30–35) → 286 (35–40) → 0. |
| Whisper re-run on the 50:07→53:45 gap | Nothing but two "Угу" and the classic silence hallucination ("Субтитры сделал DimaTorzok") — i.e. the user's answers **were never in the audio**. |
| Noise-floor scan (5th/25th percentile of 100 ms RMS, 2-min windows) | Room-noise floor present until ~32 min (p25 ≈ −34 dB, <3 % of frames below −70 dB), then collapses to digital silence (p25 ≈ −75 dB, 38–73 % of frames below −70 dB). |
| High-frequency signature (>9 kHz vs full band) | Two clearly separable groups: the user's turns ≈ −37 dB, the other speaker's ≈ −25 dB — consistent for turns labelled the same way, which is how we know the labelled voices really are two different sources. |
| `volumedetect` on the mix | `max_volume: 0.0 dB` everywhere — **the mix was clipping**. |
| iCloud interference | Ruled out: `~/Documents/Transcriber Recordings` is a local folder, not the iCloud Drive "Documents". |

### Diagnosis

The **microphone capture died mid-recording** (around 32–38 min) while the system-audio tap
kept going to the end. `amix=duration=longest` then padded the missing microphone with silence,
so the file looks complete and nothing anywhere said otherwise.

Two code paths made that possible, both in `AudioRecorder`:

1. **No liveness monitoring.** `AVAudioEngine` stops delivering tap buffers when the input device
   or its format changes (headphones connecting, a call app switching devices, a sample-rate
   change) and posts `AVAudioEngineConfigurationChange`. We never observed that notification and
   never checked whether buffers were still arriving, so a dead tap looked exactly like silence.
2. **Errors were swallowed.** `guard (try? file.write(from:)) != nil else { return }` dropped
   every failed buffer without counting it, and the mono converter was built once from the
   *initial* input format — after a device change it would fail on every buffer, forever.

Compounding it: the per-source tracks were deleted after a successful mix, so the intact
system-audio track was destroyed too, and nothing about the failure reached the transcript.

## 2. What is fixed now

- **Watchdog.** A 1 Hz check on the recorder: no mic buffer for 2.5 s (buffers arrive regardless
  of loudness, so this only means failure) ⇒ mark the mic dead, show it **red** in the recording
  bar ("Microphone not responding"), and try to restart the tap, with a 5 s cooldown.
- **Device changes handled.** `AVAudioEngineConfigurationChange` is observed and the tap is
  reinstalled with the *new* input format.
- **Converter follows the format.** `MicWriter` rebuilds its converter whenever a buffer's format
  differs from the last one, so a device switch mid-recording keeps writing (resampled) into the
  same file instead of failing silently.
- **Dropped buffers are counted** and surfaced, during and after recording.
- **Track lengths are compared on stop.** `AudioRecorder.trackMismatch` compares mic vs system
  duration; more than 5 s apart ⇒ a plain-language warning naming which side died and when
  ("The microphone stopped after 32:10 while system audio continued to 1:07:06 — everything
  after 32:10 has only one side of the conversation").
- **The warning is unmissable and durable:** an alert on stop, an orange line in the job row,
  and `recording_warning:` in the transcript's YAML frontmatter (persisted in history too).
- **The isolated tracks are kept** (`<name>.mic.m4a`, `<name>.system.m4a`) — on by default,
  toggleable in Settings → Recording. Nothing is unrecoverable, and each file has exactly one
  voice in it. Also listed as `tracks:` in the frontmatter.
- **Clipping fixed.** The mix is now `amix=…:normalize=0,alimiter=limit=0.97`: both sides keep
  full level, the sum no longer slams into 0 dB (verified: −0.3 dB peak on a doubled signal).
- **Summary attribution.** The default prompt now states that speakers appear as `**Name**` before
  a timestamp and that statements must never be moved between speakers — the reported error
  (the therapist's two-week holiday reported as the user's trip) is exactly that failure mode.

Covered by `--selftest-heuristics` (mismatch messages, ffmpeg progress parsing).

## 3. Still open: speaker attribution (spec)

The label errors have a structural cause, separate from the capture bug: **we mix both sides into
one mono track and then ask a diarizer to separate them by voice embedding** — throwing away the
one piece of information that makes it trivial. Your voice is the microphone; theirs is the system
tap. In that session the diarizer also split the therapist into two clusters (the frontmatter
listed three speakers, two of which the user renamed to the same person).

### Proposed dual-track mode

Now that `.mic.m4a` / `.system.m4a` are kept, the pipeline can use them:

1. Convert each track to 16 kHz mono WAV (cheap, two extra ffmpeg passes).
2. **Diarize the system track only.** It contains just the far side, so clustering is both easier
   and can't confuse the two sides. Multi-person calls still get Speaker 1/2/… on that side.
3. **Derive the user's turns from the mic track** by energy/VAD — no clustering needed, and label
   them "You" (renameable as today).
4. Resolve overlaps by comparing per-segment energy between the two tracks.
5. **Transcribe each side from its own track** rather than from the mix, so neither voice bleeds
   into the other's chunks — this should also improve accuracy for both.

Expected result: for a two-party call, attribution becomes deterministic instead of statistical.

Cost: ~150–250 lines (a small 16-bit WAV reader for per-segment energy, plus a pipeline branch),
and it only applies to recordings made by the app — imported files keep today's behaviour.

Not built yet: it changes the core transcription path, and validating it properly needs a real
two-sided call, not a synthetic fixture. Worth doing next.
