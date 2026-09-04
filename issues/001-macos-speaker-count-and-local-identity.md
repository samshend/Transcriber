# 001 — macOS: participant count and local-speaker identity

- **Status:** open
- **Priority:** P1
- **Platform:** macOS
- **Type:** bug / parity
- **Found:** 2026-09-04, while fixing the equivalent Windows recording path

## Problem

The macOS app does not ask how many people participated after a recording ends and does not store
the local user's name. As a result, the microphone side is still written as `Speaker 1`, and mixed
or microphone-only recordings cannot use a known participant count to constrain diarization.

There is an additional multi-party bug in the source-aware path: whenever usable microphone and
system tracks exist, the whole system track is assigned to `Speaker 2`. A call with the local user
plus two or more remote participants therefore collapses every remote voice into one speaker.

## Evidence in the current implementation

- `AppState.stopRecordingAndTranscribe()` immediately queues transcription without a participant
  count prompt.
- `Diarizer.diarize()` exposes `minSpeakers` and `maxSpeakers`, but callers leave both unset.
- `AppState` has no persisted local-user-name setting.
- `DualTrackTranscriber.transcribe()` defaults the mic to `Speaker 1` and the entire system track
  to `Speaker 2`.
- `Diarizer` caches its manager by threshold only. If speaker bounds become configurable, those
  bounds must also be part of the cache key.
- Phantom-speaker cleanup currently always runs; it should not override an exact user-selected
  count.

## Intended behaviour

1. Onboarding/settings ask for and persist the user's name.
2. After a meeting recording ends, the app asks for the participant count before transcription.
3. Imported audio offers the same count choice, including experimental auto-detection.
4. With healthy isolated tracks:
   - the microphone track is labelled with the user's name;
   - for exactly two participants, the system track is the second speaker;
   - for three or more, diarize the system track into `participant count - 1` remote speakers.
5. With microphone-only app recordings, diarize the shared track with the selected count and use
   the first detected voice as the local-user hint. Record in frontmatter that this identity was
   inferred rather than deterministic.
6. Mixed imported files never receive the user's name automatically because they have no reliable
   local-track provenance.

## Implementation notes

- Pass an exact count to FluidAudio as `minSpeakers == maxSpeakers == requestedCount`.
- Include threshold, minimum, and maximum speakers in the cached diarizer-manager configuration.
- Skip phantom-cluster merging when the user selected an exact count.
- Extend the source-track path rather than mixing tracks before attribution.
- Keep manual **Rename Speakers** as the correction mechanism because inferred identity can be
  wrong when someone else speaks first into a shared microphone.
- The sherpa-onnx retry added on Windows is engine-specific and should not be copied blindly;
  validate FluidAudio behaviour with short, acoustically played-back voices on an actual Mac.

## Acceptance criteria

- A two-person mic-only test where one voice is played from a phone produces two labels when the
  user selects two participants.
- The first/local voice uses the saved user name; the other remains a generic speaker until renamed.
- A normal two-sided call with isolated tracks always labels the mic track with the saved name.
- A local user plus two remote participants produces three distinct labels from isolated tracks.
- Choosing an exact count cannot be undone by phantom-speaker cleanup.
- Auto-detection retains the existing tuned threshold and phantom-speaker protection.
- Restarting the app preserves the user name.
- Automated tests cover count propagation, diarizer cache invalidation, mic naming, mic-only
  inference, and the 3+ hybrid-track path.
