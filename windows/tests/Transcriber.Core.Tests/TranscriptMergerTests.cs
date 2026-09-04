using Transcriber.Core;

namespace Transcriber.Core.Tests;

/// <summary>
/// Ports the merging assertions from the macOS app's --selftest-heuristics so both products
/// are held to the same behaviour. See FORMAT.md.
/// </summary>
public class TranscriptMergerTests
{
    [Fact]
    public void SpeakerAttributionUsesGreatestOverlap()
    {
        var speakers = new[]
        {
            new SpeakerSegment("Speaker 1", 0, 5.5),
            new SpeakerSegment("Speaker 2", 5.5, 12),
        };

        var speaker = SpeakerAttribution.Resolve(new TranscriptSegment(4, 9, "handover"), speakers);

        Assert.Equal("Speaker 2", speaker);
    }

    [Fact]
    public void SpeakerAttributionUsesNearestTurnWhenThereIsNoOverlap()
    {
        var speakers = new[]
        {
            new SpeakerSegment("Speaker 1", 0, 3),
            new SpeakerSegment("Speaker 2", 8, 12),
        };

        var speaker = SpeakerAttribution.Resolve(new TranscriptSegment(6.5, 7, "near second"), speakers);

        Assert.Equal("Speaker 2", speaker);
    }

    [Fact]
    public void WordAttributionStabilizesAFalseBoundaryFlipWithinASentence()
    {
        var words = new[]
        {
            Seg(10.0, 10.3, "This"), Seg(10.3, 10.6, "document"),
            Seg(10.6, 10.8, "won't"), Seg(10.8, 11.2, "change."),
            Seg(12.0, 12.2, "Okay,"), Seg(12.2, 12.5, "got"), Seg(12.5, 12.8, "it."),
        };
        var timeline = new[]
        {
            new SpeakerSegment("Speaker 2", 9.5, 10.5),
            new SpeakerSegment("Speaker 1", 10.5, 10.75), // noisy micro-flip
            new SpeakerSegment("Speaker 2", 10.75, 11.5),
            new SpeakerSegment("Speaker 1", 11.8, 13),
        };

        var units = SpeakerAttribution.AttributeUtterances(words, timeline);

        Assert.Equal(2, units.Count);
        Assert.Equal("Speaker 2", units[0].Speaker);
        Assert.Equal("This document won't change.", units[0].Segment.Text);
        Assert.Equal("Speaker 1", units[1].Speaker);
        Assert.Equal("Okay, got it.", units[1].Segment.Text);
    }

    private static TranscriptSegment Seg(double start, double end, string text) => new(start, end, text);

    [Fact]
    public void ThirteenFragmentsOfOneTurnBecomeOneOrTwoParagraphs()
    {
        // The real failure: a 2:16 voice message rendered as 13 stamped fragments because
        // each 2 s pause started a new block.
        var fragments = Enumerable.Range(0, 13)
            .Select(i => Seg(i * 10, i * 10 + 8, $"Fragment {i} with no final punctuation"))
            .ToList();

        var blocks = TranscriptMerger.Merge(fragments);

        Assert.InRange(blocks.Count, 1, 2);
        Assert.Equal(0, blocks[0].Start);
    }

    [Fact]
    public void LongPauseStartsANewParagraph()
    {
        var segments = new[] { Seg(0, 5, "First turn."), Seg(30, 35, "Much later turn.") };

        Assert.Equal(2, TranscriptMerger.Merge(segments).Count);
    }

    [Fact]
    public void SpeakerChangeAlwaysSplitsEvenWithATinyGap()
    {
        var segments = new[] { Seg(0, 5, "Question?"), Seg(5.2, 11, "Answer.") };

        var blocks = TranscriptMerger.Merge(
            segments,
            segment => segment.Start < 5 ? "Speaker 1" : "Speaker 2");

        Assert.Equal(2, blocks.Count);
        Assert.NotEqual(blocks[0].Speaker, blocks[1].Speaker);
    }

    [Fact]
    public void DualTrackMergeInterleavesChronologicallyByTag()
    {
        // Mirrors the real dual-track path: mic and system tracks are transcribed separately,
        // each segment already knows its speaker with certainty, and the only job left is to
        // lay both tracks out on one shared timeline in the order people actually spoke.
        var tagged = new (TranscriptSegment Segment, string? Speaker)[]
        {
            (Seg(0, 5, "So, could you confirm your nationality?"), "Speaker 2"),
            (Seg(5.5, 9, "German and Russian, so both."), "Speaker 1"),
            (Seg(9.2, 13, "And where do you currently live?"), "Speaker 2"),
        };

        var blocks = TranscriptMerger.Merge(tagged);

        Assert.Equal(3, blocks.Count);
        Assert.Equal("Speaker 2", blocks[0].Speaker);
        Assert.Equal("Speaker 1", blocks[1].Speaker);
        Assert.Equal("Speaker 2", blocks[2].Speaker);
    }

    [Fact]
    public void DualTrackMergeNeverBleedsASentenceAcrossASpeakerHandover()
    {
        // The real failure this guards against: a real recording glued "I already have one,
        // actually. I made it in Germany." (the user, mic track) onto the end of the
        // consultant's (system track) paragraph, because clustering misattributed the
        // handover. With each segment's speaker known up front, that can't happen.
        var tagged = new (TranscriptSegment Segment, string? Speaker)[]
        {
            (Seg(0, 20, "This will be your number for the whole of your life."), "Speaker 2"),
            (Seg(20.4, 23, "I already have one, actually. I made it in Germany."), "Speaker 1"),
        };

        var blocks = TranscriptMerger.Merge(tagged);

        Assert.Equal(2, blocks.Count);
        Assert.DoesNotContain("I already have one", blocks[0].Text);
        Assert.Contains("I already have one", blocks[1].Text);
    }

    [Fact]
    public void DualTrackMergeStillCoalescesConsecutiveSameSpeakerSegments()
    {
        var tagged = new (TranscriptSegment Segment, string? Speaker)[]
        {
            (Seg(0, 5, "First part of the explanation,"), "Speaker 2"),
            (Seg(5.3, 10, "continuing right along."), "Speaker 2"),
        };

        var blocks = TranscriptMerger.Merge(tagged);

        Assert.Single(blocks);
        Assert.Equal("First part of the explanation, continuing right along.", blocks[0].Text);
    }

    [Fact]
    public void SourceTrackMergeDropsAnEchoCopyButKeepsDistinctOverlap()
    {
        var local = new (TranscriptSegment Segment, string? Speaker)[]
        {
            (Seg(0, 4, "Please send the residence permit documents."), "Anastasia"),
            (Seg(5, 8, "Yes, I will send those tomorrow."), "Anastasia"),
        };
        var remote = new (TranscriptSegment Segment, string? Speaker)[]
        {
            (Seg(0.2, 4.1, "Please send the residence permit documents"), "Speaker 2"),
            (Seg(5, 8, "The deadline is Friday."), "Speaker 2"),
        };

        var merged = SourceTrackAttribution.Merge(local, remote);

        Assert.Equal(3, merged.Count);
        Assert.DoesNotContain(merged, item => item.Speaker == "Anastasia" && item.Segment.Text.StartsWith("Please"));
        Assert.Contains(merged, item => item.Speaker == "Anastasia" && item.Segment.Text.StartsWith("Yes"));
    }

    [Fact]
    public void AutoDiarizationFoldsTinyPhantomIntoNearestRealSpeaker()
    {
        var segments = new[]
        {
            new SpeakerDiarizer.RawSpeakerSegment(1, 0, 100),
            new SpeakerDiarizer.RawSpeakerSegment(7, 100.1, 101),
            new SpeakerDiarizer.RawSpeakerSegment(2, 101.1, 201),
        };

        var cleaned = SpeakerDiarizer.MergePhantomSpeakers(segments);

        Assert.DoesNotContain(cleaned, segment => segment.Speaker == 7);
        Assert.Equal(2, cleaned.Select(segment => segment.Speaker).Distinct().Count());
    }

    [Fact]
    public void ParagraphsDoNotSplitMidSentence()
    {
        // Segments run past the 120 s cap but the text has no sentence end until the last one,
        // so the block must keep absorbing rather than cutting mid-sentence.
        var segments = new List<TranscriptSegment>();
        for (var i = 0; i < 20; i++) segments.Add(Seg(i * 10, i * 10 + 9, "and then"));
        segments.Add(Seg(200, 205, "it finally ends."));

        var blocks = TranscriptMerger.Merge(segments);

        Assert.All(blocks, block => Assert.True(
            TranscriptMerger.EndsSentence(block.Text) || block == blocks[^1],
            $"block ending '{block.Text[^Math.Min(20, block.Text.Length)..]}' split mid-sentence"));
    }

    [Fact]
    public void CapEventuallyAppliesSoOneBlockIsNotUnbounded()
    {
        // Well-punctuated speech over many minutes must break up, or a 45-minute call becomes
        // one paragraph with a single timestamp and nothing is quotable.
        var segments = Enumerable.Range(0, 60)
            .Select(i => Seg(i * 10, i * 10 + 9, "A complete sentence."))
            .ToList();

        var blocks = TranscriptMerger.Merge(segments);

        Assert.True(blocks.Count > 1, "600 s of speech should not be a single block");
        Assert.All(blocks, block => Assert.True(
            block.End - block.Start < TranscriptMerger.MaxBlockDuration + 30,
            $"block of {block.End - block.Start:F0}s far exceeds the cap"));
    }

    [Fact]
    public void EmptySegmentsAreDropped()
    {
        var segments = new[] { Seg(0, 1, "   "), Seg(2, 3, "Real text.") };

        var blocks = TranscriptMerger.Merge(segments);

        Assert.Single(blocks);
        Assert.Equal("Real text.", blocks[0].Text);
    }

    [Theory]
    [InlineData("Done.", true)]
    [InlineData("Really?", true)]
    [InlineData("Wait…", true)]
    [InlineData("trailing off", false)]
    [InlineData("", true)]
    public void EndsSentenceClassifiesBoundaries(string text, bool expected)
        => Assert.Equal(expected, TranscriptMerger.EndsSentence(text));

    [Theory]
    [InlineData(0, "00:00")]
    [InlineData(156, "02:36")]
    [InlineData(3756, "1:02:36")]
    public void LabelMatchesTheMacFormat(double seconds, string expected)
        => Assert.Equal(expected, Timecode.Label(seconds));

    [Theory]
    [InlineData(2682, "44:42")]
    [InlineData(4026, "1:07:06")]
    public void DurationMatchesTheMacFormat(double seconds, string expected)
        => Assert.Equal(expected, Timecode.Duration(seconds));
}
