using Transcriber.Core;

// Headless driver for the same pipeline the desktop app uses. It exists so the pipeline can
// be exercised on any platform — including a Mac, before the Windows UI exists — and so a
// transcript produced here can be diffed against the macOS app's output (see FORMAT.md).
//
//   Transcriber.Cli <audio-or-video file> [--language ru] [--vocabulary "NIE, TIE"]
//                   [--ffmpeg path] [--whisper path] [--model path] [--vad path] [--out dir]

var arguments = ParseArguments(args);

if (!arguments.TryGetValue("_input", out var input))
{
    Console.Error.WriteLine("usage: Transcriber.Cli <file> [--language ru] [--vocabulary \"...\"]");
    Console.Error.WriteLine("       [--ffmpeg path] [--whisper path] [--model path] [--vad path] [--out dir]");
    return 2;
}

var defaults = ToolPaths.FromAppDirectory(
    AppContext.BaseDirectory, "ggml-large-v3-turbo-q5_0.bin", "ggml-silero-v5.1.2.bin");

var tools = new ToolPaths
{
    FFmpeg = Value("ffmpeg") ?? defaults.FFmpeg,
    WhisperCli = Value("whisper") ?? defaults.WhisperCli,
    ModelPath = Value("model") ?? defaults.ModelPath,
    VadModelPath = Value("vad") ?? defaults.VadModelPath,
};

try
{
    tools.Validate();
}
catch (FileNotFoundException error)
{
    Console.Error.WriteLine($"error: {error.Message} ({error.FileName})");
    return 3;
}

if (tools.VadModelPath is null)
{
    Console.Error.WriteLine(
        "warning: no VAD model, so silence will not be skipped — expect invented sentences "
        + "in quiet stretches.");
}

var stopwatch = System.Diagnostics.Stopwatch.StartNew();
var lastReported = -1;
var progress = new Progress<PipelineProgress>(update =>
{
    switch (update.Stage)
    {
        case PipelineStage.Converting:
            Console.WriteLine("preparing audio…");
            break;
        case PipelineStage.Transcribing when update.Fraction is { } fraction:
            var percent = (int)(fraction * 100);
            if (percent >= lastReported + 10)
            {
                lastReported = percent;
                Console.WriteLine($"recognising speech… {percent}%");
            }
            break;
        case PipelineStage.Writing:
            Console.WriteLine("writing transcript…");
            break;
    }
});

try
{
    var pipeline = new TranscriptionPipeline(tools);
    var outcome = await pipeline.RunAsync(
        new TranscriptionRequest
        {
            SourcePath = input,
            Language = Value("language") ?? "auto",
            Vocabulary = Value("vocabulary"),
            OutputDirectory = Value("out"),
        },
        progress);

    stopwatch.Stop();
    Console.WriteLine();
    Console.WriteLine($"language          : {outcome.Language}");
    if (outcome.DurationSeconds is { } duration)
    {
        var speed = duration / Math.Max(0.001, stopwatch.Elapsed.TotalSeconds);
        Console.WriteLine($"audio duration    : {Timecode.Duration(duration)}");
        Console.WriteLine($"processing took   : {stopwatch.Elapsed.TotalSeconds:F1}s ({speed:F1}x realtime)");
    }
    Console.WriteLine($"segments → blocks : {outcome.SegmentCount} → {outcome.BlockCount}");
    Console.WriteLine($"markdown          : {outcome.MarkdownPath}");
    Console.WriteLine($"readable / print  : {outcome.HtmlPath}");

    // Optionally file the result into the managed library (source of truth in the app),
    // under a named project. This exercises the same transcribe → ingest path the GUI uses.
    if (Value("library") is { } libraryDir)
    {
        var store = new LibraryStore(libraryDir);
        Guid? projectId = null;
        if (Value("project") is { } projectName && projectName.Length > 0)
        {
            var existing = store.Projects.FirstOrDefault(p =>
                string.Equals(p.Name, projectName, StringComparison.OrdinalIgnoreCase));
            projectId = (existing ?? store.CreateProject(projectName)).Id;
        }
        var item = store.Ingest(outcome.MarkdownPath, audioPath: input, projectId: projectId);
        Console.WriteLine($"library item      : {item.Title}  →  {(projectId is null ? "Unsorted" : Value("project"))}");
        Console.WriteLine($"library path      : {store.TranscriptPath(item)}");
    }
    return 0;
}
catch (ToolFailure failure)
{
    Console.Error.WriteLine($"error: {failure.Message}");
    return 1;
}

string? Value(string name) => arguments.TryGetValue(name, out var found) ? found : null;

static Dictionary<string, string> ParseArguments(string[] raw)
{
    var parsed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (var index = 0; index < raw.Length; index++)
    {
        var item = raw[index];
        if (item.StartsWith("--", StringComparison.Ordinal))
        {
            var name = item[2..];
            if (index + 1 < raw.Length && !raw[index + 1].StartsWith("--", StringComparison.Ordinal))
            {
                parsed[name] = raw[++index];
            }
            else
            {
                parsed[name] = "true";
            }
        }
        else if (!parsed.ContainsKey("_input"))
        {
            parsed["_input"] = item;
        }
    }
    return parsed;
}
