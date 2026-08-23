using Transcriber.Core;

namespace Transcriber.Core.Tests;

/// <summary>
/// Ports the macOS `--selftest-library` assertions so both products' managed library behaves
/// identically (see FORMAT.md): ingest copies in, projects group and re-parent, delete removes
/// only the library copy, export writes a copy out, and migration is one-shot.
/// </summary>
public sealed class LibraryStoreTests : IDisposable
{
    private readonly string _sandbox = Path.Combine(
        Path.GetTempPath(), "transcriber-lib-tests-" + Guid.NewGuid().ToString("N"));

    private const string Fixture = """
        ---
        source: "Client call.m4a"
        type: audio
        duration: "44:42"
        transcribed: 2026-08-03T14:22:28Z
        model: whisper-large-v3-turbo
        language: ru, en
        speakers: ["Speaker 1", "Speaker 2"]
        recording_warning: "The microphone stopped after 32:10."
        diarized: true
        ---

        # Client call

        **Speaker 1**
        00:00
        Hello.
        """;

    private (LibraryStore store, string md, string audio) Setup(string libraryName = "Library")
    {
        var external = Path.Combine(_sandbox, "external");
        Directory.CreateDirectory(external);
        var md = Path.Combine(external, "Client call.md");
        var audio = Path.Combine(external, "Client call.m4a");
        File.WriteAllText(md, Fixture);
        File.WriteAllText(audio, "fake-audio");
        return (new LibraryStore(Path.Combine(_sandbox, libraryName)), md, audio);
    }

    public void Dispose()
    {
        try { Directory.Delete(_sandbox, recursive: true); } catch { }
    }

    [Fact]
    public void IngestCopiesInAndDenormalisesMetadata()
    {
        var (store, md, audio) = Setup();

        var item = store.Ingest(md, audio);

        Assert.True(File.Exists(md), "ingest must not remove the original transcript");
        Assert.True(File.Exists(store.TranscriptPath(item)), "transcript was not copied into the library");
        Assert.NotNull(store.AudioPath(item));
        Assert.True(File.Exists(store.AudioPath(item)!), "audio was not copied into the library");
        Assert.Equal(2682, item.DurationSeconds);
        Assert.Equal(2, item.Speakers.Count);
        Assert.Equal("ru, en", item.Language);
        Assert.NotNull(item.RecordingWarning);
        Assert.Null(item.ProjectId);   // a fresh item is Unsorted
    }

    [Fact]
    public void ProjectsGroupAndReParentOnDelete()
    {
        var (store, md, audio) = Setup();
        var item = store.Ingest(md, audio);

        var project = store.CreateProject("Immigration — Ivanov", "Spain residency");
        store.Move(item.Id, project.Id);
        Assert.Single(store.ItemsIn(project.Id));
        Assert.Empty(store.ItemsIn(null));

        store.DeleteProject(project.Id);
        Assert.Single(store.ItemsIn(null));   // re-homed to Unsorted, not lost
        Assert.Empty(store.Projects);
    }

    [Fact]
    public void RenameIsDisplayOnly()
    {
        var (store, md, audio) = Setup();
        var item = store.Ingest(md, audio);

        store.SetTitle(item.Id, "Ivanov — first call");

        Assert.Equal("Ivanov — first call", store.Items.First().Title);
        // The stored file keeps its original name; only the display title changed.
        Assert.True(File.Exists(store.TranscriptPath(store.Items.First())));
    }

    [Fact]
    public void ExportWritesACopyOutAndKeepsTheOriginalInLibrary()
    {
        var (store, md, audio) = Setup();
        var item = store.Ingest(md, audio);
        var destination = Path.Combine(_sandbox, "Downloads", "Ivanov call.md");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);

        store.Export(item.Id, ExportKind.Transcript, destination);

        Assert.True(File.Exists(destination), "export did not write the transcript out");
        Assert.True(File.Exists(store.TranscriptPath(item)), "export must not remove the library copy");
    }

    [Fact]
    public void IndexPersistsAcrossReopen()
    {
        var (store, md, audio) = Setup();
        store.Ingest(md, audio);

        var reopened = new LibraryStore(store.Root);

        Assert.Single(reopened.Items);
    }

    [Fact]
    public void DeleteRemovesLibraryCopyButNeverTheOriginal()
    {
        var (store, md, audio) = Setup();
        var item = store.Ingest(md, audio);
        var libraryCopy = store.TranscriptPath(item);

        store.DeleteItem(item.Id);

        Assert.False(File.Exists(libraryCopy), "delete left the library copy on disk");
        Assert.True(File.Exists(md), "delete must never touch the user's original file");
        Assert.Empty(store.Items);
    }

    [Fact]
    public void MigrationIsOneShot()
    {
        var (store, md, audio) = Setup("Library2");

        store.MigrateIfNeeded([md], _ => audio);
        var afterFirst = store.Items.Count;
        store.MigrateIfNeeded([md], _ => audio);

        Assert.Equal(1, afterFirst);
        Assert.Equal(afterFirst, store.Items.Count);   // second call imported nothing
    }

    [Theory]
    [InlineData("44:42", 2682)]
    [InlineData("1:07:06", 4026)]
    [InlineData("20", 20)]
    public void SecondsParsesDurationLabels(string label, double expected)
        => Assert.Equal(expected, LibraryStore.Seconds(label));

    [Fact]
    public void SecondsIsNullForGarbage()
        => Assert.Null(LibraryStore.Seconds("not-a-time"));

    [Theory]
    [InlineData("Client/call: v2?", "Client call v2")]
    [InlineData("   ", "transcript")]
    public void SanitizeStripsIllegalCharacters(string input, string expected)
        => Assert.Equal(expected, LibraryStore.Sanitize(input));

    [Fact]
    public void FrontmatterParsesKnownFields()
    {
        var fields = TranscriptFrontmatter.Parse(Fixture);

        Assert.Equal("Client call.m4a", fields["source"]);
        Assert.Equal("44:42", fields["duration"]);
        Assert.Equal(2, TranscriptFrontmatter.ParseList(fields["speakers"]).Count);
    }

    [Fact]
    public void HasSummaryDetectsTheMarker()
    {
        Assert.False(TranscriptFrontmatter.HasSummary(Fixture));
        Assert.True(TranscriptFrontmatter.HasSummary(Fixture + "\n<!-- SUMMARY:START -->\n…"));
    }
}
