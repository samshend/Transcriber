using Transcriber.Core;

namespace Transcriber.Core.Tests;

public class WhisperCommandTests
{
    [Fact]
    public void VadFlagsArePresentWhenAModelIsSupplied()
    {
        var arguments = WhisperCommand.AccuracyArguments("/models/silero.bin", null);

        Assert.Contains("--vad", arguments);
        Assert.Contains("/models/silero.bin", arguments);
        Assert.Contains("--suppress-nst", arguments);
    }

    [Fact]
    public void NoModelAndNoVocabularyAddsNoFlags()
        => Assert.Empty(WhisperCommand.AccuracyArguments(null, null));

    [Fact]
    public void BlankVocabularyDoesNotProduceAnEmptyPrompt()
    {
        // A "--prompt" with an empty value would bias decoding toward nothing and has caused
        // whisper to behave oddly; it must be omitted entirely.
        Assert.Empty(WhisperCommand.AccuracyArguments(null, "   \n "));
    }

    [Fact]
    public void VocabularyIsPassedAsOneArgumentAndCarried()
    {
        var arguments = WhisperCommand.AccuracyArguments(null, " NIE, TIE, arraigo ");

        var index = arguments.IndexOf("--prompt");
        Assert.True(index >= 0, "--prompt missing");
        Assert.Equal("NIE, TIE, arraigo", arguments[index + 1]);
        Assert.Contains("--carry-initial-prompt", arguments);
    }

    [Fact]
    public void BuildArgumentsRequestsJsonOutputAndIncludesAccuracyFlags()
    {
        var arguments = WhisperCommand.BuildArguments(
            "/m/model.bin", "/tmp/a.wav", "/tmp/out",
            language: "ru", vadModelPath: "/m/silero.bin", vocabulary: "Copilot", threads: 8);

        Assert.Contains("-oj", arguments);
        Assert.Equal("/tmp/out", arguments[arguments.IndexOf("-of") + 1]);
        Assert.Equal("ru", arguments[arguments.IndexOf("-l") + 1]);
        Assert.Equal("8", arguments[arguments.IndexOf("-t") + 1]);
        Assert.Contains("--vad", arguments);
        Assert.Contains("--prompt", arguments);
    }

    [Theory]
    [InlineData("whisper_print_progress_callback: progress =  35%", 0.35)]
    [InlineData("progress = 100%", 1.0)]
    public void ProgressIsParsedFromStderr(string line, double expected)
        => Assert.Equal(expected, WhisperCommand.ProgressFraction(line)!.Value, 3);

    [Theory]
    [InlineData("loading model")]
    [InlineData("")]
    public void NonProgressLinesAreIgnored(string line)
        => Assert.Null(WhisperCommand.ProgressFraction(line));

    [Fact]
    public void JsonIsParsedIntoSegmentsWithSecondsAndLanguage()
    {
        const string json = """
            {
              "result": { "language": "ru" },
              "transcription": [
                { "offsets": { "from": 1090, "to": 2090 }, "text": " Привет-привет!" },
                { "offsets": { "from": 2090, "to": 9870 }, "text": " Ну, ты правильно понял." },
                { "offsets": { "from": 9870, "to": 9999 }, "text": "   " }
              ]
            }
            """;

        var result = WhisperCommand.ParseJson(json);

        Assert.Equal("ru", result.Language);
        Assert.Equal(2, result.Segments.Count);   // the whitespace-only segment is dropped
        Assert.Equal(1.09, result.Segments[0].Start, 3);
        Assert.Equal(2.09, result.Segments[0].End, 3);
        Assert.Equal("Привет-привет!", result.Segments[0].Text);
    }

    [Fact]
    public void MissingTranscriptionArrayYieldsNoSegmentsRatherThanThrowing()
    {
        var result = WhisperCommand.ParseJson("""{ "result": { "language": "en" } }""");

        Assert.Empty(result.Segments);
        Assert.Equal("en", result.Language);
    }
}
