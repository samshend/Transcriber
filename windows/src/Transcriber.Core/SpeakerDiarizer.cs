using SherpaOnnx;

namespace Transcriber.Core;

public readonly record struct SpeakerSegment(string Speaker, double Start, double End);

/// <summary>Matches Whisper's timed text to the speaker timeline produced by diarization.</summary>
public static class SpeakerAttribution
{
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

        var labels = new Dictionary<int, string>();
        return result
            .OrderBy(segment => segment.Start)
            .Select(segment =>
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
