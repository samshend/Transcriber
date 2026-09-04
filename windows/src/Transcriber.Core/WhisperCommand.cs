using System.Text.Json;
using System.Text.Json.Serialization;

namespace Transcriber.Core;

/// <summary>Builds whisper-cli arguments and reads back its JSON output.</summary>
public static class WhisperCommand
{
    /// <summary>
    /// Flags that improve accuracy without changing the model.
    /// </summary>
    /// <remarks>
    /// <c>--vad</c> is the important one. Measured on a real recording whose microphone had
    /// died, 6 of 8 segments in one 3:38 silent window were fabricated text that was never
    /// spoken ("Субтитры создавал DimaTorzok"); with VAD the same window produced 3 segments,
    /// all real speech, and ran far faster because silence is never decoded. For a product
    /// sold as a record of what a client said, invented sentences are disqualifying.
    /// </remarks>
    public static List<string> AccuracyArguments(string? vadModelPath, string? vocabulary)
    {
        var arguments = new List<string>();

        if (!string.IsNullOrWhiteSpace(vadModelPath))
        {
            arguments.AddRange(["--vad", "-vm", vadModelPath, "--suppress-nst"]);
        }

        var terms = vocabulary?.Trim();
        if (!string.IsNullOrEmpty(terms))
        {
            // Carried so the bias applies to every window, not only the first.
            arguments.AddRange(["--prompt", terms, "--carry-initial-prompt"]);
        }

        return arguments;
    }

    public static List<string> BuildArguments(
        string modelPath,
        string wavPath,
        string outputBase,
        string language = "auto",
        string? vadModelPath = null,
        string? vocabulary = null,
        int? threads = null)
    {
        var arguments = new List<string>
        {
            "-m", modelPath,
            "-f", wavPath,
            "-l", language,
            "-t", (threads ?? Environment.ProcessorCount).ToString(),
            "-ojf", "-of", outputBase,
            "--max-len", "50", "--split-on-word",
            "--print-progress",
        };
        arguments.AddRange(AccuracyArguments(vadModelPath, vocabulary));
        return arguments;
    }

    /// <summary>whisper-cli reports "... progress =  35%" on stderr.</summary>
    public static double? ProgressFraction(string line)
    {
        var marker = line.IndexOf("progress =", StringComparison.Ordinal);
        if (marker < 0) return null;

        var tail = line[(marker + "progress =".Length)..].Trim().TrimEnd('%').Trim();
        if (!double.TryParse(tail, System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var percent))
        {
            return null;
        }
        return Math.Clamp(percent / 100.0, 0, 1);
    }

    public static WhisperResult ParseJson(string json)
    {
        var file = JsonSerializer.Deserialize<WhisperJsonFile>(json)
            ?? throw new InvalidDataException("whisper produced no readable JSON");

        var segments = new List<TranscriptSegment>();
        foreach (var segment in file.Transcription ?? [])
        {
            if (segment.Offsets is null) continue;
            var words = TimedWords(segment);
            if (words.Count > 0) segments.AddRange(words);
            else
            {
                var text = (segment.Text ?? string.Empty).Trim();
                if (text.Length == 0) continue;
                segments.Add(new TranscriptSegment(
                    segment.Offsets.From / 1000.0,
                    segment.Offsets.To / 1000.0,
                    text));
            }
        }

        return new WhisperResult(segments, file.Result?.Language);
    }

    private sealed class WhisperJsonFile
    {
        [JsonPropertyName("transcription")] public List<Segment>? Transcription { get; set; }
        [JsonPropertyName("result")] public ResultInfo? Result { get; set; }
    }

    private sealed class Segment
    {
        [JsonPropertyName("offsets")] public Offsets? Offsets { get; set; }
        [JsonPropertyName("text")] public string? Text { get; set; }
        [JsonPropertyName("tokens")] public List<Token>? Tokens { get; set; }
    }

    private sealed class Token
    {
        [JsonPropertyName("text")] public string? Text { get; set; }
        [JsonPropertyName("offsets")] public Offsets? Offsets { get; set; }
    }

    private sealed class Offsets
    {
        [JsonPropertyName("from")] public long From { get; set; }
        [JsonPropertyName("to")] public long To { get; set; }
    }

    private sealed class ResultInfo
    {
        [JsonPropertyName("language")] public string? Language { get; set; }
    }

    /// <summary>
    /// Full whisper JSON exposes timestamped tokens. With VAD their offsets are relative to the
    /// current speech window, while the parent segment is on the original file timeline; align
    /// the first lexical token to the segment start, then combine subword tokens into timed words.
    /// </summary>
    private static List<TranscriptSegment> TimedWords(Segment segment)
    {
        var tokens = (segment.Tokens ?? [])
            .Where(token => token.Offsets is not null &&
                !string.IsNullOrEmpty(token.Text) &&
                !token.Text.StartsWith("[_", StringComparison.Ordinal))
            .ToList();
        if (tokens.Count == 0 || segment.Offsets is null) return [];

        var firstOffset = tokens.Min(token => token.Offsets!.From);
        var shift = segment.Offsets.From - firstOffset;
        var words = new List<(long Start, long End, string Text)>();
        foreach (var token in tokens)
        {
            var raw = token.Text!;
            var beginsWord = char.IsWhiteSpace(raw[0]);
            var text = raw.Trim();
            if (text.Length == 0) continue;
            var start = Math.Clamp(token.Offsets!.From + shift, segment.Offsets.From, segment.Offsets.To);
            var end = Math.Clamp(token.Offsets.To + shift, start, segment.Offsets.To);
            if (beginsWord || words.Count == 0)
            {
                words.Add((start, end, text));
            }
            else
            {
                var previous = words[^1];
                words[^1] = (previous.Start, Math.Max(previous.End, end), previous.Text + text);
            }
        }
        return words.Select(word => new TranscriptSegment(
            word.Start / 1000.0,
            Math.Max(word.End, word.Start + 50) / 1000.0,
            word.Text)).ToList();
    }
}

public sealed record WhisperResult(List<TranscriptSegment> Segments, string? Language);
