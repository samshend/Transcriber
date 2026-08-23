using Transcriber.Core;

namespace Transcriber.Core.Tests;

/// <summary>
/// Ports the merging assertions from the macOS app's --selftest-heuristics so both products
/// are held to the same behaviour. See FORMAT.md.
/// </summary>
public class TranscriptMergerTests
{
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
