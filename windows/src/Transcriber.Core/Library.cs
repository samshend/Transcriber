using System.Text.Json;

namespace Transcriber.Core;

/// <summary>A user-created grouping of transcripts, like a ChatGPT/Claude project.</summary>
public sealed class Project
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = string.Empty;
    public string Notes { get; set; } = string.Empty;
    public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// One transcript in the managed library. The transcript `.md` and (optionally) a copy of the
/// source audio live in <c>Library/&lt;id&gt;/</c>; the remaining fields are denormalised from the
/// transcript's frontmatter so a list can render without opening every file.
/// </summary>
public sealed class LibraryItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid? ProjectId { get; set; }          // null == the built-in "Unsorted" bucket
    public string Title { get; set; } = string.Empty;
    public string TranscriptFile { get; set; } = string.Empty;
    public string? AudioFile { get; set; }
    public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset Modified { get; set; } = DateTimeOffset.UtcNow;

    public double? DurationSeconds { get; set; }
    public string? Language { get; set; }
    public List<string> Speakers { get; set; } = [];
    public bool HasSummary { get; set; }
    public string? RecordingWarning { get; set; }
    public string? SourceName { get; set; }
}

public sealed class LibraryIndex
{
    public int Version { get; set; } = 1;
    public List<Project> Projects { get; set; } = [];
    public List<LibraryItem> Items { get; set; } = [];
}

public enum ExportKind { Transcript, Audio }

public sealed class LibraryException(string message) : Exception(message);

/// <summary>
/// The managed library: the <c>Library/</c> folder, its <c>library.json</c> index, and every
/// mutation. Mirrors the macOS <c>LibraryStore.swift</c> (see FORMAT.md) so both products behave
/// identically. Files are copied *in* on ingest and only ever leave through <see cref="Export"/>.
/// </summary>
public sealed class LibraryStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public string Root { get; }
    private LibraryIndex _index = new();

    public LibraryStore(string root)
    {
        Root = root;
        Directory.CreateDirectory(root);
        Load();
    }

    public string IndexPath => Path.Combine(Root, "library.json");
    private string ItemFolder(Guid id) => Path.Combine(Root, id.ToString("D"));

    // --- reads ---------------------------------------------------------------------------

    public IReadOnlyList<Project> Projects => _index.Projects.OrderBy(p => p.Created).ToList();
    public IReadOnlyList<LibraryItem> Items => _index.Items.OrderByDescending(i => i.Modified).ToList();
    public IReadOnlyList<LibraryItem> ItemsIn(Guid? projectId) =>
        Items.Where(i => i.ProjectId == projectId).ToList();

    public string TranscriptPath(LibraryItem item) => Path.Combine(ItemFolder(item.Id), item.TranscriptFile);
    public string? AudioPath(LibraryItem item) =>
        item.AudioFile is null ? null : Path.Combine(ItemFolder(item.Id), item.AudioFile);

    // --- projects ------------------------------------------------------------------------

    public Project CreateProject(string name, string notes = "")
    {
        var project = new Project { Name = name.Trim(), Notes = notes };
        _index.Projects.Add(project);
        Save();
        return project;
    }

    public void RenameProject(Guid id, string name)
    {
        var project = _index.Projects.FirstOrDefault(p => p.Id == id);
        if (project is null) return;
        project.Name = name.Trim();
        Save();
    }

    public void SetNotes(Guid id, string notes)
    {
        var project = _index.Projects.FirstOrDefault(p => p.Id == id);
        if (project is null) return;
        project.Notes = notes;
        Save();
    }

    /// <summary>Deleting a project keeps its transcripts — they fall back to Unsorted.</summary>
    public void DeleteProject(Guid id)
    {
        foreach (var item in _index.Items.Where(i => i.ProjectId == id))
        {
            item.ProjectId = null;
        }
        _index.Projects.RemoveAll(p => p.Id == id);
        Save();
    }

    // --- items ---------------------------------------------------------------------------

    /// <summary>
    /// Copies a transcript (and optionally its audio) into the library and records it. The
    /// originals are never modified.
    /// </summary>
    public LibraryItem Ingest(
        string transcriptPath,
        string? audioPath = null,
        Guid? projectId = null,
        string? title = null,
        bool copyAudio = true)
    {
        var id = Guid.NewGuid();
        var folder = ItemFolder(id);
        Directory.CreateDirectory(folder);

        var displayTitle = title ?? Path.GetFileNameWithoutExtension(transcriptPath);
        var mdName = Sanitize(displayTitle) + ".md";
        var mdDestination = Path.Combine(folder, mdName);
        File.Copy(transcriptPath, mdDestination, overwrite: true);

        string? audioName = null;
        if (copyAudio && audioPath is not null && File.Exists(audioPath))
        {
            var name = Sanitize(displayTitle) + Path.GetExtension(audioPath);
            var destination = Path.Combine(folder, name);
            try
            {
                File.Copy(audioPath, destination, overwrite: true);
                if (File.Exists(destination)) audioName = name;
            }
            catch { /* audio copy is best-effort */ }
        }

        var item = new LibraryItem
        {
            Id = id,
            ProjectId = projectId,
            Title = displayTitle,
            TranscriptFile = mdName,
            AudioFile = audioName,
            SourceName = audioPath is null ? null : Path.GetFileName(audioPath),
        };
        ApplyMetadata(item, mdDestination);

        _index.Items.Add(item);
        Save();
        return item;
    }

    /// <summary>Refreshes denormalised fields from the transcript on disk (after editing it).</summary>
    public void RefreshMetadata(Guid id)
    {
        var item = _index.Items.FirstOrDefault(i => i.Id == id);
        if (item is null) return;
        ApplyMetadata(item, TranscriptPath(item));
        item.Modified = DateTimeOffset.UtcNow;
        Save();
    }

    public void Move(Guid id, Guid? projectId)
    {
        var item = _index.Items.FirstOrDefault(i => i.Id == id);
        if (item is null) return;
        item.ProjectId = projectId;
        item.Modified = DateTimeOffset.UtcNow;
        Save();
    }

    public void SetTitle(Guid id, string title)
    {
        var item = _index.Items.FirstOrDefault(i => i.Id == id);
        if (item is null) return;
        item.Title = title.Trim();
        item.Modified = DateTimeOffset.UtcNow;
        Save();
    }

    /// <summary>
    /// Permanently removes the library's copy (transcript + audio). Never touches anything the
    /// user has elsewhere on disk.
    /// </summary>
    public void DeleteItem(Guid id)
    {
        try { Directory.Delete(ItemFolder(id), recursive: true); } catch { /* already gone */ }
        _index.Items.RemoveAll(i => i.Id == id);
        Save();
    }

    /// <summary>Copies the stored transcript or audio out to a chosen location and name.</summary>
    public string Export(Guid id, ExportKind kind, string destination)
    {
        var item = _index.Items.FirstOrDefault(i => i.Id == id)
            ?? throw new LibraryException("transcript not found");
        var source = kind switch
        {
            ExportKind.Transcript => TranscriptPath(item),
            ExportKind.Audio => AudioPath(item),
            _ => null,
        };
        if (source is null || !File.Exists(source))
        {
            throw new LibraryException("the file to export is missing");
        }
        File.Copy(source, destination, overwrite: true);
        return destination;
    }

    // --- migration -----------------------------------------------------------------------

    private string MigrationMarker => Path.Combine(Root, ".migrated");

    /// <summary>
    /// One-time import of transcripts produced before the library existed. Copies each `.md`
    /// (and its resolved audio) into an "Unsorted" item. Idempotent via a marker file; never
    /// moves or deletes the originals.
    /// </summary>
    public void MigrateIfNeeded(IEnumerable<string> transcriptPaths, Func<string, string?>? audioResolver = null)
    {
        if (File.Exists(MigrationMarker)) return;

        foreach (var md in transcriptPaths.Where(File.Exists))
        {
            var audio = audioResolver?.Invoke(md);
            try { Ingest(md, audio); } catch { /* skip unreadable transcripts */ }
        }
        File.WriteAllText(MigrationMarker, string.Empty);
        Save();
    }

    // --- helpers -------------------------------------------------------------------------

    private void ApplyMetadata(LibraryItem item, string mdPath)
    {
        string content;
        try { content = File.ReadAllText(mdPath); } catch { return; }

        var fields = TranscriptFrontmatter.Parse(content);
        if (fields.TryGetValue("language", out var language) && language.Length > 0)
        {
            item.Language = language;
        }
        item.Speakers = TranscriptFrontmatter.ParseList(fields.GetValueOrDefault("speakers"));
        item.DurationSeconds = Seconds(fields.GetValueOrDefault("duration"));
        item.RecordingWarning = fields.GetValueOrDefault("recording_warning");
        item.HasSummary = TranscriptFrontmatter.HasSummary(content);
        item.SourceName ??= fields.GetValueOrDefault("source");
    }

    /// <summary>"44:42" / "1:07:06" → seconds.</summary>
    public static double? Seconds(string? label)
    {
        if (string.IsNullOrWhiteSpace(label)) return null;
        var parts = label.Split(':');
        double total = 0;
        foreach (var part in parts)
        {
            if (!double.TryParse(part, System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out var value))
            {
                return null;
            }
            total = total * 60 + value;
        }
        return total;
    }

    /// <summary>Filesystem-safe filename component (mirrors the Swift FileRenamer rules).</summary>
    public static string Sanitize(string name)
    {
        // Replace illegal characters with spaces, then collapse whitespace runs so we don't
        // leave awkward double spaces where a "x: y" became "x  y".
        var withoutIllegal = string.Join(" ", name.Split('/', '\\', ':', '*', '?', '"', '<', '>', '|'));
        var collapsed = string.Join(" ", withoutIllegal.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length == 0 ? "transcript" : collapsed;
    }

    private void Load()
    {
        if (!File.Exists(IndexPath)) return;
        try
        {
            var decoded = JsonSerializer.Deserialize<LibraryIndex>(File.ReadAllText(IndexPath), JsonOptions);
            if (decoded is not null) _index = decoded;
        }
        catch { /* corrupt index → start fresh rather than crash */ }
    }

    private void Save()
    {
        var json = JsonSerializer.Serialize(_index, JsonOptions);
        File.WriteAllText(IndexPath, json);
    }
}

/// <summary>
/// Reads the YAML frontmatter this app writes (a fixed, simple subset — not general YAML).
/// Mirrors <c>TranscriptIndex.frontmatter</c> on macOS so the two products read each other's files.
/// </summary>
public static class TranscriptFrontmatter
{
    public const string SummaryStart = "<!-- SUMMARY:START -->";

    public static Dictionary<string, string> Parse(string content)
    {
        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!content.StartsWith("---")) return fields;

        // Everything between the opening "---" line and the next "---" line.
        var lines = content.Replace("\r\n", "\n").Split('\n');
        for (var i = 1; i < lines.Length; i++)
        {
            var line = lines[i];
            if (line.Trim() == "---") break;
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var key = line[..colon].Trim();
            var value = line[(colon + 1)..].Trim();
            // Strip surrounding quotes from scalar string values.
            if (value.Length >= 2 && value.StartsWith('"') && value.EndsWith('"'))
            {
                value = value[1..^1];
            }
            fields[key] = value;
        }
        return fields;
    }

    /// <summary>Parses a `["a", "b"]` frontmatter list, or a comma-separated fallback.</summary>
    public static List<string> ParseList(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return [];
        var trimmed = raw.Trim();
        if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
        {
            trimmed = trimmed[1..^1];
        }
        return trimmed
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(part => part.Trim().Trim('"').Trim())
            .Where(part => part.Length > 0)
            .ToList();
    }

    public static bool HasSummary(string content) => content.Contains(SummaryStart);
}
