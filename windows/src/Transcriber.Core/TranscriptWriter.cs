using System.Text;

namespace Transcriber.Core;

public sealed record TranscriptMetadata
{
    public required string SourceFileName { get; init; }
    public string? SourcePath { get; init; }
    public double? DurationSeconds { get; init; }
    public required string Model { get; init; }
    public required string Language { get; init; }
    public DateTimeOffset Transcribed { get; init; } = DateTimeOffset.UtcNow;
    public IReadOnlyList<string> Speakers { get; init; } = [];
    public string? RecordingWarning { get; init; }
    public IReadOnlyList<string> Tracks { get; init; } = [];
    public string? Attribution { get; init; }
    public int ExpectedSpeakers { get; init; } = -1;
}

/// <summary>
/// Writes the Markdown transcript. The format is a contract shared with the macOS app
/// (FORMAT.md): identical frontmatter keys and block layout, so a file produced by either
/// product is readable by the other, by Obsidian, and by the MCP server.
/// </summary>
public static class MarkdownWriter
{
    public static string Build(IReadOnlyList<TranscriptBlock> blocks, TranscriptMetadata meta)
    {
        var text = new StringBuilder();

        text.Append("---\n");
        text.Append($"source: \"{Escape(meta.SourceFileName)}\"\n");
        if (!string.IsNullOrEmpty(meta.SourcePath))
        {
            text.Append($"source_path: \"{Escape(meta.SourcePath)}\"\n");
        }
        text.Append("type: audio\n");
        if (meta.DurationSeconds is { } duration)
        {
            text.Append($"duration: \"{Timecode.Duration(duration)}\"\n");
        }
        text.Append($"transcribed: {meta.Transcribed.ToUniversalTime():yyyy-MM-ddTHH:mm:ssZ}\n");
        text.Append($"model: whisper-{meta.Model}\n");
        text.Append($"language: {meta.Language}\n");
        if (meta.Speakers.Count > 0)
        {
            var names = string.Join(", ", meta.Speakers.Select(s => $"\"{Escape(s)}\""));
            text.Append($"speakers: [{names}]\n");
            text.Append("diarized: true\n");
        }
        if (!string.IsNullOrEmpty(meta.RecordingWarning))
        {
            // Quotes inside YAML values are replaced rather than escaped, matching the Swift writer.
            text.Append($"recording_warning: \"{meta.RecordingWarning.Replace('"', '\'')}\"\n");
        }
        if (meta.Tracks.Count > 0)
        {
            var names = string.Join(", ", meta.Tracks.Select(t => $"\"{Escape(t)}\""));
            text.Append($"tracks: [{names}]\n");
        }
        if (!string.IsNullOrEmpty(meta.Attribution)) text.Append($"attribution: {meta.Attribution}\n");
        if (meta.ExpectedSpeakers > 0) text.Append($"expected_speakers: {meta.ExpectedSpeakers}\n");
        text.Append("---\n\n");

        var title = Path.GetFileNameWithoutExtension(meta.SourceFileName);
        text.Append($"# {title}\n\n");
        text.Append(Body(blocks));
        text.Append('\n');

        return text.ToString();
    }

    /// <summary>
    /// Speaker-attributed blocks render as "**Name**\n02:36\ntext". Without speakers — the
    /// case until diarization lands — the timestamp alone leads the paragraph, so the text
    /// stays quotable without inventing a speaker label we do not actually know.
    /// </summary>
    public static string Body(IReadOnlyList<TranscriptBlock> blocks)
    {
        var parts = blocks.Select(block => string.IsNullOrEmpty(block.Speaker)
            ? $"**{Timecode.Label(block.Start)}**\n{block.Text}"
            : $"**{block.Speaker}**\n{Timecode.Label(block.Start)}\n{block.Text}");
        return string.Join("\n\n", parts);
    }

    // YAML double-quoted scalars treat backslashes as escape prefixes. Windows paths therefore
    // need their separators escaped as well as literal quotes.
    private static string Escape(string value) => value.Replace("\\", "\\\\").Replace("\"", "\\\"");
}

/// <summary>
/// A self-contained HTML document for reading and printing to PDF. Deliberately plain: no
/// line numbers or certification page, because the target user writes client emails rather
/// than court filings.
/// </summary>
public static class HtmlReport
{
    public static string Build(IReadOnlyList<TranscriptBlock> blocks, TranscriptMetadata meta)
    {
        var title = Path.GetFileNameWithoutExtension(meta.SourceFileName);
        var summary = new StringBuilder();
        summary.Append(meta.Transcribed.ToLocalTime().ToString("yyyy-MM-dd HH:mm"));
        if (meta.DurationSeconds is { } duration)
        {
            summary.Append(" · ").Append(Timecode.Duration(duration));
        }
        summary.Append(" · ").Append(meta.Language);

        var turns = new StringBuilder();
        foreach (var block in blocks)
        {
            var who = string.IsNullOrEmpty(block.Speaker)
                ? string.Empty
                : $"<div class=\"who\">{Encode(block.Speaker)}</div>";
            turns.Append($"""
                  <div class="turn">
                    <div class="at">{Timecode.Label(block.Start)}</div>
                    <div class="said">{who}<p>{Encode(block.Text)}</p></div>
                  </div>

                """);
        }

        var warning = string.IsNullOrEmpty(meta.RecordingWarning)
            ? string.Empty
            : $"<p class=\"warn\">{Encode(meta.RecordingWarning)}</p>";

        return $"""
            <!DOCTYPE html>
            <html lang="ru"><head><meta charset="utf-8"><title>{Encode(title)}</title>
            <style>
            {Css}
            </style></head><body>
            <h1>{Encode(title)}</h1>
            <div class="meta">{Encode(summary.ToString())}</div>
            {warning}
            {turns}</body></html>
            """;
    }

    // Kept out of the interpolated template: CSS braces would otherwise have to be doubled,
    // which is easy to get wrong and unreadable.
    private const string Css = """
          body { font: 12pt/1.65 "Segoe UI", system-ui, sans-serif; color: #111;
                 max-width: 20cm; margin: 1.5cm auto; padding: 0 1cm; }
          h1 { font-size: 17pt; margin: 0 0 .2em; }
          .meta { color: #666; font-size: 9.5pt; margin-bottom: 1.6em;
                  border-bottom: 1px solid #ddd; padding-bottom: .8em; }
          .warn { background: #fff4e5; border-left: 3px solid #e8912d; padding: .7em 1em;
                  font-size: 10pt; margin: 0 0 1.6em; }
          .turn { display: flex; gap: 1em; margin: 0 0 1em; page-break-inside: avoid; }
          .at { flex: 0 0 3.6em; color: #999; font-size: 9.5pt;
                font-variant-numeric: tabular-nums; padding-top: .3em; }
          .who { font-weight: 600; font-size: 10.5pt; margin-bottom: .15em; }
          .said p { margin: 0; }
          @page { margin: 1.8cm; }
          @media print { body { margin: 0; max-width: none; } }
        """;

    private static string Encode(string value) => value
        .Replace("&", "&amp;")
        .Replace("<", "&lt;")
        .Replace(">", "&gt;");
}
