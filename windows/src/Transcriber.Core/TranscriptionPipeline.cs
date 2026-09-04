namespace Transcriber.Core;

/// <summary>Where the bundled tools and models live. Windows ships them beside the app.</summary>
public sealed class ToolPaths
{
    public required string FFmpeg { get; init; }
    public required string WhisperCli { get; init; }
    public required string ModelPath { get; init; }
    public string? VadModelPath { get; init; }
    public string? DiarizationSegmentationModelPath { get; init; }
    public string? DiarizationEmbeddingModelPath { get; init; }
    public bool DiarizationAvailable =>
        File.Exists(DiarizationSegmentationModelPath) && File.Exists(DiarizationEmbeddingModelPath);

    /// <summary>Locates tools relative to the running app; also honours PATH-style overrides.</summary>
    public static ToolPaths FromAppDirectory(string appDirectory, string modelFileName, string vadFileName)
    {
        var bin = Path.Combine(appDirectory, "bin");
        var models = Path.Combine(appDirectory, "models");
        var executableSuffix = OperatingSystem.IsWindows() ? ".exe" : string.Empty;
        var vad = Path.Combine(models, vadFileName);

        return new ToolPaths
        {
            FFmpeg = Path.Combine(bin, "ffmpeg" + executableSuffix),
            WhisperCli = Path.Combine(bin, "whisper-cli" + executableSuffix),
            ModelPath = Path.Combine(models, modelFileName),
            VadModelPath = File.Exists(vad) ? vad : null,
            DiarizationSegmentationModelPath = Path.Combine(models, "pyannote-segmentation-3.0.onnx"),
            DiarizationEmbeddingModelPath = Path.Combine(models, "3dspeaker-eres2net-base-16k.onnx"),
        };
    }

    public void Validate()
    {
        if (!File.Exists(FFmpeg)) throw new FileNotFoundException("ffmpeg is missing", FFmpeg);
        if (!File.Exists(WhisperCli)) throw new FileNotFoundException("whisper-cli is missing", WhisperCli);
        if (!File.Exists(ModelPath)) throw new FileNotFoundException("the speech model is missing", ModelPath);
    }
}

public sealed record TranscriptionRequest
{
    public required string SourcePath { get; init; }
    public string Language { get; init; } = "auto";
    public string? Vocabulary { get; init; }
    public string? RecordingWarning { get; init; }
    public IReadOnlyList<string> Tracks { get; init; } = [];
    public bool Diarize { get; init; } = true;
    /// <summary>-1 asks clustering to infer the count; a positive value forces that count.</summary>
    public int ExpectedSpeakers { get; init; } = -1;
    public string? LogPath { get; init; }
    /// <summary>Where the .md and .html go. Defaults to the source file's folder.</summary>
    public string? OutputDirectory { get; init; }
}

public sealed record TranscriptionOutcome(
    string MarkdownPath,
    string HtmlPath,
    int SegmentCount,
    int BlockCount,
    string Language,
    double? DurationSeconds);

/// <summary>
/// convert → recognise → merge → write. Shared by the desktop app and the CLI so both
/// behave identically, and so this can be exercised on a Mac before the Windows UI exists.
/// </summary>
public sealed class TranscriptionPipeline(ToolPaths tools)
{
    public async Task<TranscriptionOutcome> RunAsync(
        TranscriptionRequest request,
        IProgress<PipelineProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        using var log = new PipelineLog(request.LogPath);
        log.Write($"START source={request.SourcePath}");
        log.Write($"MODEL path={tools.ModelPath}");
        log.Write($"OPTIONS language={request.Language} diarize={request.Diarize} threads={Environment.ProcessorCount}");
        tools.Validate();
        if (!File.Exists(request.SourcePath))
        {
            throw new FileNotFoundException("the recording could not be found", request.SourcePath);
        }

        var workDirectory = Path.Combine(Path.GetTempPath(), "transcriber-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDirectory);
        try
        {
            var duration = await ProbeDurationAsync(request.SourcePath, cancellationToken).ConfigureAwait(false);
            log.Write($"PROBE duration_seconds={duration?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "unknown"}");

            // Deterministic attribution when the recording kept isolated mic/system tracks:
            // transcribe each side separately and merge on the shared timeline, instead of
            // guessing speakers by clustering the mix. Null for imported/mixed files or a
            // dead/silent side — those fall through to the mix+clustering path below.
            var dualTrack = request.Diarize
                ? await TryDualTrackAsync(request, workDirectory, log, progress, cancellationToken).ConfigureAwait(false)
                : null;

            List<TranscriptBlock> blocks;
            string? language;
            int segmentCount;

            if (dualTrack is not null)
            {
                progress?.Report(new PipelineProgress(PipelineStage.Writing, null, "Writing transcript…"));
                log.Write($"STAGE dual_track_complete segments={dualTrack.Segments.Count}");
                blocks = TranscriptMerger.Merge(dualTrack.Segments);
                language = dualTrack.Languages.Count == 0
                    ? request.Language
                    : string.Join(", ", dualTrack.Languages);
                segmentCount = dualTrack.Segments.Count;
            }
            else
            {
                progress?.Report(new PipelineProgress(PipelineStage.Converting, null, "Converting audio…"));
                log.Write("STAGE converting");
                var wavPath = Path.Combine(workDirectory, "audio.wav");
                await ProcessRunner.RunOrThrowAsync(
                    tools.FFmpeg,
                    ["-hide_banner", "-nostdin", "-y", "-i", request.SourcePath,
                     "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wavPath],
                    "ffmpeg",
                    cancellationToken: cancellationToken).ConfigureAwait(false);

                progress?.Report(new PipelineProgress(
                    PipelineStage.Transcribing, null, "Loading model and analyzing speech regions…"));
                log.Write("STAGE whisper_start");
                var outputBase = Path.Combine(workDirectory, "result");
                await ProcessRunner.RunOrThrowAsync(
                    tools.WhisperCli,
                    WhisperCommand.BuildArguments(
                        tools.ModelPath, wavPath, outputBase,
                        request.Language, tools.VadModelPath, request.Vocabulary),
                    "whisper-cli",
                    line =>
                    {
                        log.Write("WHISPER " + line);
                        var fraction = WhisperCommand.ProgressFraction(line);
                        if (fraction is not null)
                        {
                            progress?.Report(new PipelineProgress(
                                PipelineStage.Transcribing, fraction, $"Transcribing… {(int)(fraction * 100)}%"));
                        }
                    },
                    cancellationToken).ConfigureAwait(false);
                log.Write("STAGE whisper_complete");

                var jsonPath = outputBase + ".json";
                if (!File.Exists(jsonPath))
                {
                    throw new ToolFailure("whisper-cli", 0, "no transcript was produced");
                }

                var recognised = WhisperCommand.ParseJson(
                    await File.ReadAllTextAsync(jsonPath, cancellationToken).ConfigureAwait(false));
                if (recognised.Segments.Count == 0)
                {
                    throw new ToolFailure("whisper-cli", 0, "no speech was detected in this file");
                }

                IReadOnlyList<SpeakerSegment> speakerSegments = [];
                if (request.Diarize && tools.DiarizationAvailable)
                {
                    progress?.Report(new PipelineProgress(PipelineStage.Diarizing, 0, "Detecting speakers… 0%"));
                    log.Write("STAGE diarization_start");
                    speakerSegments = await Task.Run(() => SpeakerDiarizer.Process(
                        wavPath,
                        tools.DiarizationSegmentationModelPath!,
                        tools.DiarizationEmbeddingModelPath!,
                        fraction =>
                        {
                            log.Write($"DIARIZATION progress={(int)(fraction * 100)}%");
                            progress?.Report(new PipelineProgress(
                                PipelineStage.Diarizing, fraction, $"Detecting speakers… {(int)(fraction * 100)}%"));
                        },
                        cancellationToken,
                        numberOfSpeakers: request.ExpectedSpeakers), cancellationToken).ConfigureAwait(false);
                    log.Write($"STAGE diarization_complete segments={speakerSegments.Count}");
                }

                progress?.Report(new PipelineProgress(PipelineStage.Writing, null, "Writing transcript…"));
                log.Write("STAGE writing");
                blocks = TranscriptMerger.Merge(
                    recognised.Segments,
                    speakerSegments.Count == 0 ? null : segment => SpeakerAttribution.Resolve(segment, speakerSegments));
                language = recognised.Language ?? request.Language;
                segmentCount = recognised.Segments.Count;
            }

            var speakers = blocks.Select(block => block.Speaker).OfType<string>().Distinct().ToList();

            var source = new FileInfo(request.SourcePath);
            var meta = new TranscriptMetadata
            {
                SourceFileName = source.Name,
                SourcePath = source.FullName,
                DurationSeconds = duration,
                Model = Path.GetFileNameWithoutExtension(tools.ModelPath).Replace("ggml-", string.Empty),
                Language = language,
                RecordingWarning = request.RecordingWarning,
                Tracks = request.Tracks,
                Speakers = speakers,
            };

            var directory = request.OutputDirectory ?? source.DirectoryName!;
            Directory.CreateDirectory(directory);
            var stem = Path.GetFileNameWithoutExtension(source.Name);
            var markdownPath = UniquePath(directory, stem, ".md");
            var htmlPath = UniquePath(directory, stem, ".html");

            await WriteUtf8Async(markdownPath, MarkdownWriter.Build(blocks, meta), cancellationToken)
                .ConfigureAwait(false);
            await WriteUtf8Async(htmlPath, HtmlReport.Build(blocks, meta), cancellationToken)
                .ConfigureAwait(false);

            progress?.Report(new PipelineProgress(PipelineStage.Done, 1));
            log.Write($"DONE segments={segmentCount} blocks={blocks.Count} speakers={speakers.Count}");
            return new TranscriptionOutcome(
                markdownPath, htmlPath, segmentCount, blocks.Count,
                meta.Language, duration);
        }
        finally
        {
            try { Directory.Delete(workDirectory, recursive: true); } catch { /* best effort */ }
        }
    }

    /// <summary>
    /// Looks for the isolated <c>microphone.wav</c>/<c>system.wav</c> siblings a recording
    /// leaves next to its merged <c>.m4a</c> (see <c>RecordingSession.cs</c>) and, if both carry
    /// real audio, transcribes each separately instead of clustering the mix. Returns null for
    /// imported/mixed files (no siblings) or a dead/silent side (e.g. denied system-audio
    /// capture) — those fall back to the existing mix+clustering path unchanged.
    /// </summary>
    private async Task<DualTrackResult?> TryDualTrackAsync(
        TranscriptionRequest request,
        string workDirectory,
        PipelineLog log,
        IProgress<PipelineProgress>? progress,
        CancellationToken cancellationToken)
    {
        var folder = Path.GetDirectoryName(request.SourcePath);
        if (folder is null) return null;
        var micPath = Path.Combine(folder, "microphone.wav");
        var systemPath = Path.Combine(folder, "system.wav");
        if (!File.Exists(micPath) || !File.Exists(systemPath)) return null;

        var micDuration = await ProbeDurationAsync(micPath, cancellationToken).ConfigureAwait(false);
        var systemDuration = await ProbeDurationAsync(systemPath, cancellationToken).ConfigureAwait(false);
        if (micDuration is not > 1 || systemDuration is not > 1) return null;

        log.Write("STAGE dual_track_attribution");
        progress?.Report(new PipelineProgress(PipelineStage.Transcribing, 0, "Transcribing your side…"));
        var mic = await TranscribeTrackAsync(
            "Speaker 1", micPath, workDirectory, request,
            fraction => progress?.Report(new PipelineProgress(
                PipelineStage.Transcribing, fraction * 0.5, $"Transcribing your side… {(int)(fraction * 100)}%")),
            log, cancellationToken).ConfigureAwait(false);

        progress?.Report(new PipelineProgress(PipelineStage.Transcribing, 0.5, "Transcribing the other side…"));
        var system = await TranscribeTrackAsync(
            "Speaker 2", systemPath, workDirectory, request,
            fraction => progress?.Report(new PipelineProgress(
                PipelineStage.Transcribing, 0.5 + fraction * 0.5, $"Transcribing the other side… {(int)(fraction * 100)}%")),
            log, cancellationToken).ConfigureAwait(false);

        var tagged = mic.Tagged.Concat(system.Tagged).OrderBy(t => t.Segment.Start).ToList();
        var languages = new[] { mic.Language, system.Language }.OfType<string>().Distinct().ToList();
        return new DualTrackResult(tagged, languages);
    }

    private async Task<TrackResult> TranscribeTrackAsync(
        string speaker,
        string trackPath,
        string workDirectory,
        TranscriptionRequest request,
        Action<double> onProgress,
        PipelineLog log,
        CancellationToken cancellationToken)
    {
        var safe = speaker.Replace(' ', '_');
        var wavPath = Path.Combine(workDirectory, safe + ".wav");
        await ProcessRunner.RunOrThrowAsync(
            tools.FFmpeg,
            ["-hide_banner", "-nostdin", "-y", "-i", trackPath,
             "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wavPath],
            "ffmpeg",
            cancellationToken: cancellationToken).ConfigureAwait(false);

        var outputBase = Path.Combine(workDirectory, safe + "-result");
        await ProcessRunner.RunOrThrowAsync(
            tools.WhisperCli,
            WhisperCommand.BuildArguments(
                tools.ModelPath, wavPath, outputBase,
                request.Language, tools.VadModelPath, request.Vocabulary),
            "whisper-cli",
            line =>
            {
                log.Write($"WHISPER[{speaker}] " + line);
                var fraction = WhisperCommand.ProgressFraction(line);
                if (fraction is not null) onProgress(fraction.Value);
            },
            cancellationToken).ConfigureAwait(false);

        var jsonPath = outputBase + ".json";
        if (!File.Exists(jsonPath))
        {
            throw new ToolFailure("whisper-cli", 0, $"no transcript was produced for {speaker}");
        }
        var recognised = WhisperCommand.ParseJson(
            await File.ReadAllTextAsync(jsonPath, cancellationToken).ConfigureAwait(false));
        var tagged = recognised.Segments
            .Select(segment => (Segment: segment, Speaker: (string?)speaker))
            .ToList();
        return new TrackResult(tagged, recognised.Language);
    }

    private sealed record DualTrackResult(
        List<(TranscriptSegment Segment, string? Speaker)> Segments,
        IReadOnlyList<string> Languages);

    private sealed record TrackResult(
        List<(TranscriptSegment Segment, string? Speaker)> Tagged,
        string? Language);

    /// <summary>ffmpeg prints "Duration: 00:44:42.06" on stderr; there is no ffprobe bundled.</summary>
    private async Task<double?> ProbeDurationAsync(string path, CancellationToken cancellationToken)
    {
        var result = await ProcessRunner.RunAsync(
            tools.FFmpeg, ["-hide_banner", "-i", path], cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        var match = System.Text.RegularExpressions.Regex.Match(
            result.StandardError, @"Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d+)");
        if (!match.Success) return null;

        return int.Parse(match.Groups[1].Value) * 3600
             + int.Parse(match.Groups[2].Value) * 60
             + int.Parse(match.Groups[3].Value)
             + double.Parse("0." + match.Groups[4].Value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string UniquePath(string directory, string stem, string extension)
    {
        var candidate = Path.Combine(directory, stem + extension);
        var counter = 2;
        while (File.Exists(candidate))
        {
            candidate = Path.Combine(directory, $"{stem}-{counter}{extension}");
            counter++;
        }
        return candidate;
    }

    /// <summary>UTF-8 without a BOM, so the Markdown pastes cleanly into other tools.</summary>
    private static Task WriteUtf8Async(string path, string content, CancellationToken cancellationToken)
        => File.WriteAllTextAsync(path, content, new System.Text.UTF8Encoding(false), cancellationToken);
}

public enum PipelineStage { Converting, Transcribing, Diarizing, Writing, Done }

public readonly record struct PipelineProgress(PipelineStage Stage, double? Fraction, string? Message = null);

internal sealed class PipelineLog : IDisposable
{
    private readonly StreamWriter? _writer;
    private readonly object _gate = new();

    public PipelineLog(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        _writer = new StreamWriter(path, append: true, new System.Text.UTF8Encoding(false)) { AutoFlush = true };
    }

    public void Write(string message)
    {
        lock (_gate) _writer?.WriteLine($"{DateTimeOffset.Now:O} {message}");
    }

    public void Dispose() => _writer?.Dispose();
}
