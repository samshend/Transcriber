# Windows transcription performance

_Last measured: 2026-08-25. Keep results tied to the exact hardware, model, and binary below._

## Development laptop

- Windows 11 25H2
- Intel Core i7-6700HQ: 4 physical cores / 8 logical processors
- NVIDIA GeForce GTX 1060: 6 GB VRAM, Pascal compute capability 6.1
- 16 GB system RAM
- NVIDIA driver 582.66; driver reports CUDA 13.0 capability
- Whisper model: `ggml-large-v3-turbo-q5_0.bin` (~547 MiB)
- whisper.cpp 1.9.2

## CPU versus CUDA benchmark

The benchmark used the same 30-second English excerpt, mono 16 kHz PCM, VAD enabled, and the
same large-v3-turbo q5 model. Times include process/model startup because that is what users wait
for when each import launches `whisper-cli`.

| Backend | Threads | Wall time | Result |
|---|---:|---:|---|
| CPU (`ggml-cpu-haswell.dll`) | 8 | ~38 s | Fastest measured configuration |
| CUDA 12.4, warm run | 8 | ~41 s | ~8% slower than CPU |
| CUDA 12.4, first run | 8 | ~46 s | DLL/model startup makes short jobs worse |
| CPU (`ggml-cpu-haswell.dll`) | 4 | ~54 s | Physical-core count was not optimal |

The official CUDA binary loaded successfully, detected all 6 GB VRAM, and recognized the GTX
1060 as compute capability 6.1. The disappointing result is therefore not a missing driver or a
CPU fallback. Pascal has no tensor cores, and CUDA/model-transfer startup cancels out its compute
benefit on this workload. Keep the eight-thread CPU binary as the default unless a longer-file
benchmark proves otherwise.

The temporary CUDA test package is `whisper-cublas-12.4.0-bin-x64` from the official whisper.cpp
1.9.2 release. It was deliberately not copied into `windows/bin`.

## Pipeline bottlenecks

1. Whisper transcription dominates total time.
2. sherpa-onnx speaker diarization is noticeable but normally shorter than Whisper.
3. FFmpeg conversion/mixing and Markdown/library writes usually take seconds.

## Apparent stalls and diagnostics

Whisper may show no numeric percentage while it loads the model, reads the converted WAV, and
analyzes VAD speech regions. The UI now describes that pre-progress phase instead of displaying a
misleading `0%`.

The processing UI uses four user-facing stages with weighted overall progress: **Prepare**
(0–8%), **Transcribe** (8–80%), **Speakers** (80–97%), and **Save** (97–100%). Percentages from
Whisper and sherpa-onnx are mapped only within their stage; non-measurable work names the current
operation without inventing a fake percentage.

One 2026-08-25 investigation also found an orphaned `whisper-cli` left by an older app instance.
It had no living parent, had accumulated more than 13,500 CPU-seconds, and competed with the new
job for all eight logical processors. Closing Transcriber now cancels its active pipeline and
terminates FFmpeg/Whisper children, preventing invisible background jobs.

Every new job writes a live timestamped log to `%LOCALAPPDATA%\Transcriber\Logs`. The **Logs**
toolbar button opens that folder. Logs include the selected model, options, duration, stage
boundaries, raw Whisper diagnostic lines/progress, diarization progress, and final counts. Failed
jobs retain their logs; temporary converted audio is still cleaned up.

The active progress panel also exposes **Stop transcription**. It immediately disables itself,
shows `Cancelling transcription…`, cancels the pipeline token, terminates the active FFmpeg or
Whisper child process, and removes only that job's temporary files. Existing library items and the
user's source recording are not modified.

## User-selectable quality

The Windows app exposes three multilingual models in **Settings → Transcription quality**:

| Setting | Model | Approx. disk | Intended use |
|---|---|---:|---|
| Faster | `small-q5_1` | 182 MB | quick drafts and long low-risk recordings |
| Balanced | `medium-q5_0` | 515 MB | middle ground |
| More accurate | `large-v3-turbo-q5_0` | 547 MB | important meetings; current default |

Quantization reduces size and can improve speed with some accuracy cost. Model choice must remain
explicit: never silently downgrade an important meeting. The selected setting is persisted under
`%LOCALAPPDATA%\Transcriber\settings.json`, and transcript metadata records the actual model.

## Future benchmark rules

- Use the same extracted WAV, language, VAD options, vocabulary, and thread count.
- Record cold and warm startup separately.
- Test at least a 30-second excerpt and a 10+ minute real meeting.
- Compare transcript quality, not speed alone—especially names, numbers, and mixed languages.
- Retest CUDA on a tensor-core GPU; do not generalize the GTX 1060 result to modern NVIDIA cards.

References: [whisper.cpp models](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md),
[CUDA/Vulkan build documentation](https://github.com/ggml-org/whisper.cpp/blob/master/README.md).
