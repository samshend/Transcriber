using Transcriber.Core;

namespace Transcriber.Core.Tests;

public class MarkdownWriterTests
{
    [Fact]
    public void WindowsPathsAreEscapedInsideYamlStrings()
    {
        var markdown = MarkdownWriter.Build(
            [new TranscriptBlock { Start = 0, End = 1, Text = "Hello" }],
            new TranscriptMetadata
            {
                SourceFileName = "call.m4a",
                SourcePath = @"C:\Users\Person\call.m4a",
                Model = "large-v3-turbo",
                Language = "en",
                Tracks = ["microphone.wav", "system.wav"],
            });

        Assert.Contains("source_path: \"C:\\\\Users\\\\Person\\\\call.m4a\"", markdown);
        Assert.Contains("tracks: [\"microphone.wav\", \"system.wav\"]", markdown);
    }
}
