using CommunityToolkit.Mvvm.ComponentModel;
using Transcriber.Core;

namespace Transcriber.App.ViewModels;

/// <summary>
/// Binding wrapper around a <see cref="LibraryItem"/>. Exposes display-friendly strings so the
/// XAML stays declarative, plus the project name for the "already categorised" badge.
/// </summary>
public sealed partial class TranscriptItemViewModel : ObservableObject
{
    public LibraryItem Item { get; }

    public TranscriptItemViewModel(LibraryItem item, string? projectName)
    {
        Item = item;
        _projectName = projectName;
    }

    public Guid Id => Item.Id;
    public string Title => Item.Title;

    /// <summary>e.g. "44:42 · RU · 2 speakers".</summary>
    public string Subtitle
    {
        get
        {
            var parts = new List<string>();
            if (Item.DurationSeconds is { } d) parts.Add(Timecode.Duration(d));
            if (!string.IsNullOrEmpty(Item.Language)) parts.Add(Item.Language!.ToUpperInvariant());
            if (Item.Speakers.Count > 0) parts.Add($"{Item.Speakers.Count} speakers");
            return string.Join("  ·  ", parts);
        }
    }

    public bool HasWarning => !string.IsNullOrEmpty(Item.RecordingWarning);
    public string? Warning => Item.RecordingWarning;
    public bool HasAudio => Item.AudioFile is not null;

    [ObservableProperty]
    private string? _projectName;

    /// <summary>Show the project pill only when a project is set and the list mixes projects.</summary>
    public bool ShowProjectBadge => ShowBadges && !string.IsNullOrEmpty(ProjectName);

    private bool _showBadges;
    public bool ShowBadges
    {
        get => _showBadges;
        set { if (SetProperty(ref _showBadges, value)) OnPropertyChanged(nameof(ShowProjectBadge)); }
    }

    partial void OnProjectNameChanged(string? value) => OnPropertyChanged(nameof(ShowProjectBadge));
}
