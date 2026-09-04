namespace Transcriber.Core;

/// <summary>One timed chunk as speech recognition produced it, typically 10–30 seconds.</summary>
public readonly record struct TranscriptSegment(double Start, double End, string Text);

/// <summary>A readable paragraph: consecutive segments from one speaker, merged.</summary>
public sealed class TranscriptBlock
{
    public string? Speaker { get; set; }
    public double Start { get; set; }
    public double End { get; set; }
    public string Text { get; set; } = string.Empty;
}

/// <summary>
/// Groups recognition segments into paragraphs a human can read.
/// </summary>
/// <remarks>
/// Mirrors <c>TranscriptMerger.swift</c> in the macOS app so both products emit the same
/// shape — see FORMAT.md. The thresholds matter: a real 2:16 voice message was rendered as
/// thirteen separate stamped fragments because an ordinary breath (over 1.5 s) started a new
/// block. A pause under <see cref="MaxGap"/> now continues the paragraph, paragraphs are
/// capped near <see cref="MaxBlockDuration"/>, and the cap only applies at a sentence
/// boundary so nothing splits mid-sentence.
/// </remarks>
public static class TranscriptMerger
{
    public const double MaxGap = 3.0;
    public const double MaxBlockDuration = 120.0;

    private const string SentenceEnders = ".!?…:;";

    public static bool EndsSentence(string text)
    {
        var trimmed = text.AsSpan().TrimEnd();
        return trimmed.IsEmpty || SentenceEnders.Contains(trimmed[^1]);
    }

    /// <param name="speakerAt">
    /// Resolves who was speaking at a point in time. Null means speakers are unknown, which
    /// is the case until diarization or dual-track attribution is wired in; blocks then carry
    /// no speaker and are split purely on timing.
    /// </param>
    public static List<TranscriptBlock> Merge(
        IEnumerable<TranscriptSegment> segments,
        Func<TranscriptSegment, string?>? speakerAt = null)
        => MergeCore(segments.Select(segment => (Segment: segment, Speaker: speakerAt?.Invoke(segment))));

    /// <summary>
    /// For dual-track attribution, where each segment already carries the speaker its own
    /// track was recorded for — mic and system-audio are two physically separate sources, so
    /// there's no time-based resolution to do, just a chronological merge of both tracks'
    /// segments. Pass segments pre-sorted by <see cref="TranscriptSegment.Start"/>.
    /// </summary>
    public static List<TranscriptBlock> Merge(IEnumerable<(TranscriptSegment Segment, string? Speaker)> taggedSegments)
        => MergeCore(taggedSegments);

    private static List<TranscriptBlock> MergeCore(IEnumerable<(TranscriptSegment Segment, string? Speaker)> tagged)
    {
        var blocks = new List<TranscriptBlock>();

        foreach (var (segment, speaker) in tagged)
        {
            var text = segment.Text.Trim();
            if (text.Length == 0) continue;

            var last = blocks.Count > 0 ? blocks[^1] : null;

            var continues =
                last is not null &&
                last.Speaker == speaker &&
                segment.Start - last.End < MaxGap &&
                (segment.End - last.Start < MaxBlockDuration || !EndsSentence(last.Text));

            if (continues)
            {
                last!.Text = last.Text + ' ' + text;
                last.End = segment.End;
            }
            else
            {
                blocks.Add(new TranscriptBlock
                {
                    Speaker = speaker,
                    Start = segment.Start,
                    End = segment.End,
                    Text = text,
                });
            }
        }

        return blocks;
    }
}

/// <summary>Timestamp formatting shared by every output format.</summary>
public static class Timecode
{
    /// <summary>"02:36", or "1:02:36" once past an hour. Zero-padded like the macOS app.</summary>
    public static string Label(double seconds)
    {
        var total = (int)Math.Round(Math.Max(0, seconds));
        var hours = total / 3600;
        var minutes = total % 3600 / 60;
        var secs = total % 60;
        return hours > 0
            ? $"{hours}:{minutes:00}:{secs:00}"
            : $"{minutes:00}:{secs:00}";
    }

    /// <summary>Unpadded form used for durations in frontmatter: "44:42", "1:07:06".</summary>
    public static string Duration(double seconds)
    {
        var total = (int)Math.Round(Math.Max(0, seconds));
        var hours = total / 3600;
        var minutes = total % 3600 / 60;
        var secs = total % 60;
        return hours > 0
            ? $"{hours}:{minutes:00}:{secs:00}"
            : $"{minutes}:{secs:00}";
    }
}
