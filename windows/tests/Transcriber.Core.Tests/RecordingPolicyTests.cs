using Transcriber.Core;

namespace Transcriber.Core.Tests;

public class RecordingPolicyTests
{
    [Fact]
    public void TwoTracksAreMixedWithLimiterAndLongestDuration()
    {
        var args = RecordingPolicy.BuildFinalizeArguments(["mic.wav", "system.wav"], "final.m4a");
        var filter = args[args.ToList().IndexOf("-filter_complex") + 1];

        Assert.Contains("amix=inputs=2:duration=longest", filter);
        Assert.Contains("normalize=0", filter);
        Assert.Contains("alimiter=limit=0.97", filter);
    }

    [Fact]
    public void OneTrackDoesNotAddMixFilter()
    {
        var args = RecordingPolicy.BuildFinalizeArguments(["mic.wav"], "final.m4a");
        Assert.DoesNotContain("-filter_complex", args);
    }

    [Fact]
    public void SimilarTrackLengthsHaveNoWarning()
    {
        var warning = RecordingPolicy.BuildWarning(
            TimeSpan.FromMinutes(20), TimeSpan.FromMinutes(20) + TimeSpan.FromSeconds(4), true, true);
        Assert.Null(warning);
    }

    [Fact]
    public void MaterialMismatchNamesTheShortTrack()
    {
        var warning = RecordingPolicy.BuildWarning(
            TimeSpan.FromMinutes(12), TimeSpan.FromMinutes(20), true, true);
        Assert.Contains("microphone track ended early", warning);
        Assert.Contains("12:00 mic vs 20:00 system audio", warning);
    }

    [Fact]
    public void MissingSystemAudioWarnsThatOtherSideMayBeMissing()
    {
        var warning = RecordingPolicy.BuildWarning(TimeSpan.FromMinutes(1), TimeSpan.Zero, true, false);
        Assert.Contains("other side", warning);
    }
}
