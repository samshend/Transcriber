using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Transcriber.Core;

namespace Transcriber.App.ViewModels;

/// <summary>Sidebar selection: All / Unsorted / a specific project.</summary>
public enum LibrarySelectionKind { All, Unsorted, Project }

public sealed record LibrarySelection(LibrarySelectionKind Kind, Guid? ProjectId = null)
{
    public static readonly LibrarySelection All = new(LibrarySelectionKind.All);
    public static readonly LibrarySelection Unsorted = new(LibrarySelectionKind.Unsorted);
    public static LibrarySelection Project(Guid id) => new(LibrarySelectionKind.Project, id);
}

/// <summary>One sidebar row. <paramref name="AcceptsDrop"/> marks a bucket a transcript can be
/// dragged into; <paramref name="ProjectId"/> is null for Unsorted.</summary>
public sealed record NavNode(string Title, string Glyph, LibrarySelection Selection, bool AcceptsDrop, Guid? ProjectId);

/// <summary>
/// The window's view model. Wraps <see cref="LibraryStore"/> (the verified, tested Core type)
/// and exposes observable collections the XAML binds to. All mutations go through the store and
/// then re-project into the collections, so the UI and disk never drift.
/// </summary>
public sealed partial class LibraryViewModel : ObservableObject
{
    public LibraryStore Store { get; }

    public ObservableCollection<Project> Projects { get; } = [];
    public ObservableCollection<TranscriptItemViewModel> Items { get; } = [];
    /// One row per sidebar entry (All / Unsorted / each project). Drop-target rows accept a
    /// dragged transcript.
    public ObservableCollection<NavNode> Nav { get; } = [];

    [ObservableProperty]
    private LibrarySelection _selection = LibrarySelection.All;

    [ObservableProperty]
    private TranscriptItemViewModel? _selectedItem;

    [ObservableProperty]
    private bool _isBusy;

    [ObservableProperty]
    private string? _statusMessage;

    [ObservableProperty]
    private string? _lastLogPath;

    [ObservableProperty]
    private double _processingProgress;

    [ObservableProperty]
    private string _processingDetail = string.Empty;

    [ObservableProperty]
    private bool _canCancelProcessing;

    private CancellationTokenSource? _importCancellation;
    private TaskCompletionSource _processingCompletion = CompletedProcessingSource();

    public LibraryViewModel(LibraryStore store)
    {
        Store = store;
        ReloadProjects();
        ReloadItems();
    }

    partial void OnSelectionChanged(LibrarySelection value) => ReloadItems();

    public string SelectionTitle => Selection.Kind switch
    {
        LibrarySelectionKind.All => "All Transcripts",
        LibrarySelectionKind.Unsorted => "Unsorted",
        _ => Store.Projects.FirstOrDefault(p => p.Id == Selection.ProjectId)?.Name ?? "Project",
    };

    private string? ProjectName(Guid? id) =>
        id is null ? null : Store.Projects.FirstOrDefault(p => p.Id == id)?.Name;

    public void ReloadProjects()
    {
        Projects.Clear();
        foreach (var project in Store.Projects) Projects.Add(project);

        Nav.Clear();
        Nav.Add(new NavNode("All", "", LibrarySelection.All, AcceptsDrop: false, null));
        Nav.Add(new NavNode("Unsorted", "", LibrarySelection.Unsorted, AcceptsDrop: true, null));
        foreach (var project in Store.Projects)
        {
            Nav.Add(new NavNode(project.Name, "", LibrarySelection.Project(project.Id), AcceptsDrop: true, project.Id));
        }
    }

    public void ReloadItems()
    {
        var showBadges = Selection.Kind == LibrarySelectionKind.All;
        var source = Selection.Kind switch
        {
            LibrarySelectionKind.All => Store.Items,
            LibrarySelectionKind.Unsorted => Store.ItemsIn(null),
            _ => Store.ItemsIn(Selection.ProjectId),
        };

        var previouslySelected = SelectedItem?.Id;
        Items.Clear();
        foreach (var item in source)
        {
            Items.Add(new TranscriptItemViewModel(item, ProjectName(item.ProjectId)) { ShowBadges = showBadges });
        }
        SelectedItem = Items.FirstOrDefault(i => i.Id == previouslySelected);
        OnPropertyChanged(nameof(SelectionTitle));
    }

    // --- project actions -----------------------------------------------------------------

    public void CreateProject(string name)
    {
        var project = Store.CreateProject(name);
        ReloadProjects();
        Selection = LibrarySelection.Project(project.Id);
    }

    public void RenameProject(Guid id, string name) { Store.RenameProject(id, name); ReloadProjects(); OnPropertyChanged(nameof(SelectionTitle)); }
    public void SetProjectNotes(Guid id, string notes) => Store.SetNotes(id, notes);

    public void DeleteProject(Guid id)
    {
        Store.DeleteProject(id);
        if (Selection is { Kind: LibrarySelectionKind.Project } s && s.ProjectId == id)
        {
            Selection = LibrarySelection.All;
        }
        ReloadProjects();
        ReloadItems();
    }

    // --- item actions --------------------------------------------------------------------

    public void MoveItem(Guid itemId, Guid? projectId)
    {
        Store.Move(itemId, projectId);
        ReloadItems();
    }

    public void RenameItem(Guid itemId, string title) { Store.SetTitle(itemId, title); ReloadItems(); }
    public void RenameSpeakers(Guid itemId, IReadOnlyDictionary<string, string> replacements)
    {
        Store.RenameSpeakers(itemId, replacements);
        ReloadItems();
    }

    public void DeleteItem(Guid itemId)
    {
        Store.DeleteItem(itemId);
        if (SelectedItem?.Id == itemId) SelectedItem = null;
        ReloadItems();
    }

    public string Export(Guid itemId, ExportKind kind, string destination) =>
        Store.Export(itemId, kind, destination);

    public string ExportName(TranscriptItemViewModel vm, ExportKind kind) => kind switch
    {
        ExportKind.Transcript => LibraryStore.Sanitize(vm.Title) + ".md",
        ExportKind.Audio => LibraryStore.Sanitize(vm.Title) + Path.GetExtension(vm.Item.AudioFile ?? ".m4a"),
        _ => LibraryStore.Sanitize(vm.Title),
    };

    // --- transcription -------------------------------------------------------------------

    /// <summary>
    /// Transcribes an imported file and files it into the current project (or Unsorted). Runs the
    /// verified Core pipeline on a background thread; the caller marshals UI updates.
    /// </summary>
    public async Task ImportAsync(
        string sourcePath,
        ToolPaths tools,
        string language,
        string? vocabulary,
        string? recordingWarning = null,
        IReadOnlyList<string>? tracks = null,
        int expectedSpeakers = -1,
        string localSpeakerName = "You")
    {
        IsBusy = true;
        _processingCompletion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        CanCancelProcessing = true;
        StatusMessage = $"Transcribing {Path.GetFileName(sourcePath)}…";
        ProcessingProgress = 1;
        ProcessingDetail = "Step 1 of 4 · Inspecting recording…";
        _importCancellation = new CancellationTokenSource();
        var cancellationToken = _importCancellation.Token;
        var logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Transcriber", "Logs");
        Directory.CreateDirectory(logDirectory);
        LastLogPath = Path.Combine(logDirectory,
            $"{DateTime.Now:yyyyMMdd-HHmmss}-{LibraryStore.Sanitize(Path.GetFileNameWithoutExtension(sourcePath))}.log");
        try
        {
            var projectId = Selection.Kind == LibrarySelectionKind.Project ? Selection.ProjectId : null;
            var workDir = Path.Combine(Path.GetTempPath(), "transcriber-import-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workDir);
            try
            {
                var pipeline = new TranscriptionPipeline(tools);
                var progress = new Progress<PipelineProgress>(ApplyPipelineProgress);
                var outcome = await Task.Run(() => pipeline.RunAsync(new TranscriptionRequest
                {
                    SourcePath = sourcePath,
                    Language = language,
                    Vocabulary = vocabulary,
                    RecordingWarning = recordingWarning,
                    Tracks = tracks ?? [],
                    ExpectedSpeakers = expectedSpeakers,
                    LocalSpeakerName = localSpeakerName,
                    OutputDirectory = workDir,
                    LogPath = LastLogPath,
                }, progress, cancellationToken)).ConfigureAwait(true);

                Store.Ingest(outcome.MarkdownPath, audioPath: sourcePath, projectId: projectId);
                ReloadItems();
                StatusMessage = $"Added “{Path.GetFileNameWithoutExtension(sourcePath)}”.";
                ProcessingProgress = 100;
            }
            finally
            {
                try { Directory.Delete(workDir, recursive: true); } catch { }
            }
        }
        catch (OperationCanceledException)
        {
            StatusMessage = "Transcription cancelled.";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Transcription failed: {ex.Message} (see Logs)";
        }
        finally
        {
            IsBusy = false;
            CanCancelProcessing = false;
            _importCancellation?.Dispose();
            _importCancellation = null;
            _processingCompletion.TrySetResult();
        }
    }

    public void CancelProcessing()
    {
        if (_importCancellation is null || _importCancellation.IsCancellationRequested) return;
        ProcessingDetail = "Cancelling transcription…";
        StatusMessage = "Cancelling transcription…";
        CanCancelProcessing = false;
        _importCancellation.Cancel();
    }

    public Task WaitForProcessingAsync() => _processingCompletion.Task;

    private static TaskCompletionSource CompletedProcessingSource()
    {
        var source = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        source.SetResult();
        return source;
    }

    private void ApplyPipelineProgress(PipelineProgress update)
    {
        var message = update.Message ?? update.Stage.ToString();
        switch (update.Stage)
        {
            case PipelineStage.Converting:
                ProcessingProgress = 3;
                ProcessingDetail = $"Step 1 of 4 · {message}";
                break;
            case PipelineStage.Transcribing:
                ProcessingProgress = update.Fraction is { } transcription
                    ? 8 + transcription * 72
                    : 8;
                ProcessingDetail = $"Step 2 of 4 · {message}";
                break;
            case PipelineStage.Diarizing:
                ProcessingProgress = 80 + (update.Fraction ?? 0) * 17;
                ProcessingDetail = $"Step 3 of 4 · {message}";
                break;
            case PipelineStage.Writing:
                ProcessingProgress = 98;
                ProcessingDetail = $"Step 4 of 4 · {message}";
                break;
            case PipelineStage.Done:
                ProcessingProgress = 100;
                ProcessingDetail = "Complete";
                break;
        }
        StatusMessage = message;
    }

}
