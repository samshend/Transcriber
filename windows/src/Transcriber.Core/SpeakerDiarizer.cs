using SherpaOnnx;

namespace Transcriber.Core;

public readonly record struct SpeakerSegment(string Speaker, double Start, double End);

/// <summary>Matches Whisper's timed text to the speaker timeline produced by diarization.</summary>
public static class SpeakerAttribution
{
    public const double MaxUtteranceDuration = 12;
    public const double UtterancePause = 0.8;

    public static string Resolve(TranscriptSegment segment, IReadOnlyList<SpeakerSegment> speakers)
    {
        if (speakers.Count == 0) return "Speaker 1";

        var overlapBySpeaker = new Dictionary<string, double>();
        foreach (var candidate in speakers)
        {
            var overlap = Math.Min(segment.End, candidate.End) - Math.Max(segment.Start, candidate.Start);
            if (overlap > 0)
                overlapBySpeaker[candidate.Speaker] = overlapBySpeaker.GetValueOrDefault(candidate.Speaker) + overlap;
        }
        if (overlapBySpeaker.Count > 0)
            return overlapBySpeaker.MaxBy(pair => pair.Value).Key;

        var midpoint = (segment.Start + segment.End) / 2;
        return speakers.MinBy(candidate => Distance(midpoint, candidate)).Speaker;
    }

    private static double Distance(double point, SpeakerSegment segment) => point switch
    {
        _ when point < segment.Start => segment.Start - point,
        _ when point > segment.End => point - segment.End,
        _ => 0,
    };

    /// <summary>
    /// Word timestamps are precise enough to expose a handover inside a Whisper segment but too
    /// noisy to label independently. Group them into short punctuation/pause-bounded utterances,
    /// then resolve each unit from all of its overlap with the diarization timeline.
    /// </summary>
    public static List<(TranscriptSegment Segment, string? Speaker)> AttributeUtterances(
        IReadOnlyList<TranscriptSegment> words,
        IReadOnlyList<SpeakerSegment> speakers)
    {
        var units = new List<TranscriptSegment>();
        foreach (var word in words)
        {
            if (string.IsNullOrWhiteSpace(word.Text)) continue;
            if (units.Count == 0)
            {
                units.Add(word);
                continue;
            }
            var previous = units[^1];
            var split = TranscriptMerger.EndsSentence(previous.Text) ||
                word.Start - previous.End >= UtterancePause ||
                word.End - previous.Start >= MaxUtteranceDuration;
            if (split)
            {
                units.Add(word);
            }
            else
            {
                units[^1] = previous with
                {
                    End = Math.Max(previous.End, word.End),
                    Text = previous.Text + " " + word.Text,
                };
            }
        }
        return units.Select(unit => (Segment: unit,
            Speaker: speakers.Count == 0 ? null : (string?)Resolve(unit, speakers))).ToList();
    }
}

/// <summary>Offline, local speaker diarization through sherpa-onnx.</summary>
public static class SpeakerDiarizer
{
    public static IReadOnlyList<SpeakerSegment> Process(
        string mono16KhzWavePath,
        string segmentationModelPath,
        string embeddingModelPath,
        Action<double>? progress = null,
        CancellationToken cancellationToken = default,
        float clusteringThreshold = 0.9f,
        int numberOfSpeakers = -1)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = segmentationModelPath;
        config.Segmentation.NumThreads = Math.Max(1, Environment.ProcessorCount / 2);
        config.Embedding.Model = embeddingModelPath;
        config.Embedding.NumThreads = Math.Max(1, Environment.ProcessorCount / 2);
        // In the native/C# API -1 means automatic speaker count. Zero is not "auto" and can
        // explode a short two-person call into dozens of clusters. Higher thresholds merge
        // more aggressively; sherpa's own unknown-count example recommends 0.90.
        config.Clustering.NumClusters = numberOfSpeakers;
        config.Clustering.Threshold = clusteringThreshold;

        using var diarizer = new OfflineSpeakerDiarization(config);
        var (samples, sampleRate) = PcmWave.ReadMono16(mono16KhzWavePath);
        if (sampleRate != diarizer.SampleRate)
            throw new InvalidDataException($"Diarizer expects {diarizer.SampleRate} Hz audio, got {sampleRate} Hz.");

        var callback = new OfflineSpeakerDiarizationProgressCallback((completed, total, _) =>
        {
            if (total > 0) progress?.Invoke(Math.Clamp((double)completed / total, 0, 1));
            return cancellationToken.IsCancellationRequested ? 1 : 0;
        });
        var result = diarizer.ProcessWithCallback(samples, callback, IntPtr.Zero);
        cancellationToken.ThrowIfCancellationRequested();

        var raw = result
            .OrderBy(segment => segment.Start)
            .Select(segment => new RawSpeakerSegment(segment.Speaker, segment.Start, segment.End))
            .ToList();
        if (numberOfSpeakers < 0) raw = MergePhantomSpeakers(raw);

        var labels = new Dictionary<int, string>();
        return raw.Select(segment =>
            {
                if (!labels.TryGetValue(segment.Speaker, out var label))
                {
                    label = $"Speaker {labels.Count + 1}";
                    labels[segment.Speaker] = label;
                }
                return new SpeakerSegment(label, segment.Start, segment.End);
            })
            .ToList();
    }

    public readonly record struct RawSpeakerSegment(int Speaker, double Start, double End)
    {
        public double Duration => Math.Max(0, End - Start);
    }

    /// <summary>
    /// Auto-clustering occasionally invents a speaker for a few seconds of noise or a short
    /// acknowledgement. Fold only clusters that are both under 3% of speech and under 45 seconds
    /// into the nearest established neighbour. Exact-count diarization never uses this heuristic.
    /// </summary>
    public static List<RawSpeakerSegment> MergePhantomSpeakers(
        IReadOnlyList<RawSpeakerSegment> segments,
        double maxShare = 0.03,
        double maxDuration = 45)
    {
        if (segments.Count < 2) return segments.ToList();
        var durations = segments.GroupBy(segment => segment.Speaker)
            .ToDictionary(group => group.Key, group => group.Sum(segment => segment.Duration));
        if (durations.Count <= 2) return segments.ToList();
        var total = durations.Values.Sum();
        if (total <= 0) return segments.ToList();
        var phantoms = durations
            .Where(pair => pair.Value / total < maxShare && pair.Value < maxDuration)
            .Select(pair => pair.Key)
            .ToHashSet();
        if (phantoms.Count == 0 || durations.Count - phantoms.Count < 2) return segments.ToList();

        var cleaned = segments.ToList();
        for (var index = 0; index < cleaned.Count; index++)
        {
            if (!phantoms.Contains(cleaned[index].Speaker)) continue;
            (int Speaker, double Gap)? previous = null;
            (int Speaker, double Gap)? next = null;
            for (var candidate = index - 1; candidate >= 0; candidate--)
            {
                if (phantoms.Contains(cleaned[candidate].Speaker)) continue;
                previous = (cleaned[candidate].Speaker, cleaned[index].Start - cleaned[candidate].End);
                break;
            }
            for (var candidate = index + 1; candidate < cleaned.Count; candidate++)
            {
                if (phantoms.Contains(cleaned[candidate].Speaker)) continue;
                next = (cleaned[candidate].Speaker, cleaned[candidate].Start - cleaned[index].End);
                break;
            }
            var replacement = previous is not null && next is not null
                ? (previous.Value.Gap <= next.Value.Gap ? previous.Value.Speaker : next.Value.Speaker)
                : previous?.Speaker ?? next?.Speaker;
            if (replacement is { } speaker) cleaned[index] = cleaned[index] with { Speaker = speaker };
        }
        return cleaned;
    }
}

/// <summary>Combines isolated source-track results and removes obvious acoustic echo copies.</summary>
public static class SourceTrackAttribution
{
    public static List<(TranscriptSegment Segment, string? Speaker)> Merge(
        IReadOnlyList<(TranscriptSegment Segment, string? Speaker)> local,
        IReadOnlyList<(TranscriptSegment Segment, string? Speaker)> remote)
    {
        var localWithoutEcho = local.Where(candidate => !remote.Any(other =>
            MeaningfulOverlap(candidate.Segment, other.Segment) &&
            WordSimilarity(candidate.Segment.Text, other.Segment.Text) >= 0.65)).ToList();
        return localWithoutEcho.Concat(remote).OrderBy(item => item.Segment.Start).ToList();
    }

    private static bool MeaningfulOverlap(TranscriptSegment left, TranscriptSegment right)
    {
        var overlap = Math.Min(left.End, right.End) - Math.Max(left.Start, right.Start);
        var shorter = Math.Min(left.End - left.Start, right.End - right.Start);
        return overlap > 0 && shorter > 0 && overlap / shorter >= 0.5;
    }

    internal static double WordSimilarity(string left, string right)
    {
        static HashSet<string> Words(string value) => System.Text.RegularExpressions.Regex
            .Matches(value.ToLowerInvariant(), @"[\p{L}\p{N}]+")
            .Select(match => match.Value)
            .Where(word => word.Length > 1)
            .ToHashSet();
        var a = Words(left);
        var b = Words(right);
        if (a.Count == 0 || b.Count == 0) return 0;
        var intersection = a.Intersect(b).Count();
        return 2d * intersection / (a.Count + b.Count);
    }
}

internal static class PcmWave
{
    public static (float[] Samples, int SampleRate) ReadMono16(string path)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream);
        if (new string(reader.ReadChars(4)) != "RIFF") throw new InvalidDataException("Not a RIFF WAV file.");
        reader.ReadUInt32();
        if (new string(reader.ReadChars(4)) != "WAVE") throw new InvalidDataException("Not a WAVE file.");

        int sampleRate = 0, channels = 0, bits = 0, format = 0;
        byte[]? audio = null;
        while (stream.Position + 8 <= stream.Length)
        {
            var id = new string(reader.ReadChars(4));
            var size = reader.ReadUInt32();
            if (id == "fmt ")
            {
                format = reader.ReadUInt16();
                channels = reader.ReadUInt16();
                sampleRate = reader.ReadInt32();
                reader.ReadUInt32();
                reader.ReadUInt16();
                bits = reader.ReadUInt16();
                stream.Position += size - 16;
            }
            else if (id == "data") audio = reader.ReadBytes(checked((int)size));
            else stream.Position += size;
            if ((size & 1) != 0 && stream.Position < stream.Length) stream.Position++;
        }

        if (format != 1 || channels != 1 || bits != 16 || audio is null)
            throw new InvalidDataException("Diarization requires mono 16-bit PCM WAV audio.");
        var samples = new float[audio.Length / 2];
        for (var i = 0; i < samples.Length; i++)
            samples[i] = BitConverter.ToInt16(audio, i * 2) / 32768f;
        return (samples, sampleRate);
    }
}
