namespace Transcriber.Core;

/// <summary>Where the bundled tools and models live. Windows ships them beside the app.</summary>
public sealed class ToolPaths
{
    public required string FFmpeg { get; init; }
    public required string WhisperCli { get; init; }
    public required string ModelPath { get; init; }
    public string? VadModelPath { get; init; }

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

            progress?.Report(new PipelineProgress(PipelineStage.Converting, null));
            var wavPath = Path.Combine(workDirectory, "audio.wav");
            await ProcessRunner.RunOrThrowAsync(
                tools.FFmpeg,
                ["-hide_banner", "-nostdin", "-y", "-i", request.SourcePath,
                 "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wavPath],
                "ffmpeg",
                cancellationToken: cancellationToken).ConfigureAwait(false);

            progress?.Report(new PipelineProgress(PipelineStage.Transcribing, 0));
            var outputBase = Path.Combine(workDirectory, "result");
            await ProcessRunner.RunOrThrowAsync(
                tools.WhisperCli,
                WhisperCommand.BuildArguments(
                    tools.ModelPath, wavPath, outputBase,
                    request.Language, tools.VadModelPath, request.Vocabulary),
                "whisper-cli",
                line =>
                {
                    var fraction = WhisperCommand.ProgressFraction(line);
                    if (fraction is not null)
                    {
                        progress?.Report(new PipelineProgress(PipelineStage.Transcribing, fraction));
                    }
                },
                cancellationToken).ConfigureAwait(false);

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

            progress?.Report(new PipelineProgress(PipelineStage.Writing, null));
            var blocks = TranscriptMerger.Merge(recognised.Segments);

            var source = new FileInfo(request.SourcePath);
            var meta = new TranscriptMetadata
            {
                SourceFileName = source.Name,
                SourcePath = source.FullName,
                DurationSeconds = duration,
                Model = "large-v3-turbo",
                Language = recognised.Language ?? request.Language,
                RecordingWarning = request.RecordingWarning,
                Tracks = request.Tracks,
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
            return new TranscriptionOutcome(
                markdownPath, htmlPath, recognised.Segments.Count, blocks.Count,
                meta.Language, duration);
        }
        finally
        {
            try { Directory.Delete(workDirectory, recursive: true); } catch { /* best effort */ }
        }
    }

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

public enum PipelineStage { Converting, Transcribing, Writing, Done }

public readonly record struct PipelineProgress(PipelineStage Stage, double? Fraction);
