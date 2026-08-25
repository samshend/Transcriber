using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Transcriber.App.ViewModels;
using Transcriber.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Transcriber.App;

public sealed partial class MainWindow : Window
{
    public LibraryViewModel Vm { get; }
    private ToolPaths _tools;
    private readonly TranscriptionSettings _settings;
    private readonly DispatcherTimer _recordingTimer = new() { Interval = TimeSpan.FromMilliseconds(200) };
    private readonly MediaPlayer _audioMediaPlayer = new() { AutoPlay = false, Volume = 1.0 };
    private RecordingSession? _recording;
    private int _detailVersion;
    private bool _allowClose;
    private bool _closeCancellationInProgress;

    private const string VadFile = "ggml-silero-v5.1.2.bin";

    public MainWindow()
    {
        // The managed library lives under LocalAppData; bundled tools/models sit beside the app.
        var libraryRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Transcriber", "Library");
        Vm = new LibraryViewModel(new LibraryStore(libraryRoot));
        _settings = TranscriptionSettings.Load();
        _tools = ToolPaths.FromAppDirectory(
            AppContext.BaseDirectory, TranscriptionModels.Get(_settings.Quality).FileName, VadFile);

        InitializeComponent();
        AudioPlayer.SetMediaPlayer(_audioMediaPlayer);
        _audioMediaPlayer.MediaFailed += AudioMediaPlayer_MediaFailed;
        Closed += (_, _) => _audioMediaPlayer.Dispose();
        _recordingTimer.Tick += (_, _) => RefreshRecordingUi();
        AppWindow.Closing += AppWindow_Closing;
        NavList.SelectedIndex = 0;   // "All"
        UpdateDetail(null);
    }

    private async void AppWindow_Closing(
        Microsoft.UI.Windowing.AppWindow sender,
        Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (_allowClose) return;
        if (_recording?.State is RecordingState.Recording or RecordingState.Paused or RecordingState.Finalizing)
        {
            args.Cancel = true;
            Vm.StatusMessage = "Stop or discard the recording before closing Transcriber.";
            RecordingWarningText.Text = Vm.StatusMessage;
            return;
        }
        if (!Vm.IsBusy) return;

        args.Cancel = true;
        if (_closeCancellationInProgress) return;
        _closeCancellationInProgress = true;
        Vm.CancelProcessing();
        Vm.StatusMessage = "Stopping transcription before closing…";
        await Vm.WaitForProcessingAsync();
        _allowClose = true;
        Close();
    }

    // MARK: - Sidebar selection & drop

    private void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavList.SelectedItem is NavNode node) Vm.Selection = node.Selection;
    }

    private void Nav_DragOver(object sender, DragEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is NavNode node && node.AcceptsDrop)
        {
            e.AcceptedOperation = DataPackageOperation.Move;
            e.DragUIOverride.Caption = $"Move to {node.Title}";
        }
    }

    private async void Nav_Drop(object sender, DragEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not NavNode node || !node.AcceptsDrop) return;
        if (!e.DataView.Contains(StandardDataFormats.Text)) return;
        var text = await e.DataView.GetTextAsync();
        if (Guid.TryParse(text, out var itemId)) Vm.MoveItem(itemId, node.ProjectId);
    }

    // MARK: - Transcript list selection & drag

    private void ItemsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        Vm.SelectedItem = ItemsList.SelectedItem as TranscriptItemViewModel;
        UpdateDetail(Vm.SelectedItem);
    }

    private void ItemsList_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        if (e.Items.FirstOrDefault() is TranscriptItemViewModel vm)
        {
            e.Data.SetText(vm.Id.ToString());
            e.Data.RequestedOperation = DataPackageOperation.Move;
        }
    }

    // MARK: - Detail pane

    private async void UpdateDetail(TranscriptItemViewModel? vm)
    {
        var detailVersion = ++_detailVersion;
        var hasSelection = vm is not null;
        EmptyDetail.Visibility = hasSelection ? Visibility.Collapsed : Visibility.Visible;
        DetailTitle.Visibility = DetailMeta.Visibility = DetailBody.Visibility =
            hasSelection ? Visibility.Visible : Visibility.Collapsed;

        if (vm is null)
        {
            AudioPlayer.Visibility = Visibility.Collapsed;
            _audioMediaPlayer.Pause();
            _audioMediaPlayer.Source = null;
            PlaybackError.IsOpen = false;
            DetailWarning.IsOpen = false;
            return;
        }

        DetailTitle.Text = vm.Title;
        DetailMeta.Text = vm.Subtitle;
        DetailWarning.IsOpen = vm.HasWarning;
        DetailWarning.Message = vm.Warning ?? string.Empty;

        // Transcript text preview (frontmatter stripped).
        try
        {
            var content = await File.ReadAllTextAsync(Vm.Store.TranscriptPath(vm.Item));
            DetailBody.Text = StripFrontmatter(content);
        }
        catch
        {
            DetailBody.Text = string.Empty;
        }

        // Audio playback.
        _audioMediaPlayer.Pause();
        _audioMediaPlayer.Source = null;
        PlaybackError.IsOpen = false;
        var audioPath = Vm.Store.AudioPath(vm.Item);
        if (audioPath is not null && File.Exists(audioPath))
        {
            try
            {
                // Some Windows installations silently refuse AAC/M4A playback even though the
                // transport controls remain enabled. Decode once to PCM WAV with our bundled
                // ffmpeg so playback does not depend on an optional Windows codec.
                var playbackPath = await PreparePlaybackAudioAsync(audioPath, vm.Id);
                if (detailVersion != _detailVersion) return;
                var file = await StorageFile.GetFileFromPathAsync(playbackPath);
                if (detailVersion != _detailVersion) return;
                _audioMediaPlayer.IsMuted = false;
                _audioMediaPlayer.Volume = 1.0;
                _audioMediaPlayer.Source = MediaSource.CreateFromStorageFile(file);
                AudioPlayer.Visibility = Visibility.Visible;
            }
            catch (Exception error)
            {
                ShowPlaybackError(error.Message);
            }
        }
        else
        {
            AudioPlayer.Visibility = Visibility.Collapsed;
        }
    }

    private async Task<string> PreparePlaybackAudioAsync(string sourcePath, Guid itemId)
    {
        if (Path.GetExtension(sourcePath).Equals(".wav", StringComparison.OrdinalIgnoreCase))
            return sourcePath;

        var sourceStamp = File.GetLastWriteTimeUtc(sourcePath).Ticks;
        var cacheDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Transcriber", "PlaybackCache");
        Directory.CreateDirectory(cacheDirectory);
        var wavPath = Path.Combine(cacheDirectory, $"{itemId:N}-{sourceStamp}.wav");
        if (File.Exists(wavPath)) return wavPath;

        await ProcessRunner.RunOrThrowAsync(
            _tools.FFmpeg,
            ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", sourcePath,
             "-vn", "-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le", wavPath],
            "ffmpeg");
        return wavPath;
    }

    private void AudioMediaPlayer_MediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        DispatcherQueue.TryEnqueue(() =>
            ShowPlaybackError(string.IsNullOrWhiteSpace(args.ErrorMessage)
                ? args.ExtendedErrorCode?.Message ?? "Windows could not decode this recording."
                : args.ErrorMessage));
    }

    private void ShowPlaybackError(string message)
    {
        _audioMediaPlayer.Pause();
        AudioPlayer.Visibility = Visibility.Collapsed;
        PlaybackError.Message = message;
        PlaybackError.IsOpen = true;
    }

    /// <summary>Drops the leading <c>--- … ---</c> block for a readable preview.</summary>
    private static string StripFrontmatter(string content)
    {
        if (!content.StartsWith("---")) return content.Trim();
        var end = content.IndexOf("\n---", 3, StringComparison.Ordinal);
        return end < 0 ? content.Trim() : content[(end + 4)..].Trim();
    }

    // MARK: - Toolbar actions

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Transcriber", "Logs");
        Directory.CreateDirectory(directory);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", directory)
        {
            UseShellExecute = true,
        });
    }

    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        var slider = new Slider
        {
            Minimum = 0,
            Maximum = 2,
            StepFrequency = 1,
            IsThumbToolTipEnabled = false,
            Value = (int)_settings.Quality,
        };
        var title = new TextBlock { FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
        var description = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray),
        };
        var availability = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var labels = new Grid();
        labels.ColumnDefinitions.Add(new ColumnDefinition());
        labels.ColumnDefinitions.Add(new ColumnDefinition());
        labels.ColumnDefinitions.Add(new ColumnDefinition());
        labels.Children.Add(new TextBlock { Text = "Faster", HorizontalAlignment = HorizontalAlignment.Left });
        var balanced = new TextBlock { Text = "Balanced", HorizontalAlignment = HorizontalAlignment.Center };
        Grid.SetColumn(balanced, 1);
        labels.Children.Add(balanced);
        var accurate = new TextBlock { Text = "More accurate", HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetColumn(accurate, 2);
        labels.Children.Add(accurate);
        var panel = new StackPanel { Spacing = 8, Width = 440 };
        panel.Children.Add(title);
        panel.Children.Add(description);
        panel.Children.Add(slider);
        panel.Children.Add(labels);
        panel.Children.Add(availability);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Transcription quality",
            Content = panel,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        void RefreshChoice()
        {
            var option = TranscriptionModels.Get((TranscriptionQuality)(int)Math.Round(slider.Value));
            var modelPath = Path.Combine(AppContext.BaseDirectory, "models", option.FileName);
            title.Text = option.Title;
            description.Text = option.Description;
            var installed = File.Exists(modelPath);
            availability.Text = installed ? "Model installed and ready." : "Model is not installed. Run the Windows asset setup first.";
            availability.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                installed ? Microsoft.UI.Colors.Green : Microsoft.UI.Colors.OrangeRed);
            dialog.IsPrimaryButtonEnabled = installed;
        }
        slider.ValueChanged += (_, _) => RefreshChoice();
        RefreshChoice();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        _settings.Quality = (TranscriptionQuality)(int)Math.Round(slider.Value);
        _settings.Save();
        var selected = TranscriptionModels.Get(_settings.Quality);
        _tools = ToolPaths.FromAppDirectory(AppContext.BaseDirectory, selected.FileName, VadFile);
        Vm.StatusMessage = $"Transcription quality: {selected.Title}.";
    }

    private void StartRecording_Click(object sender, RoutedEventArgs e)
    {
        if (_recording is not null || Vm.IsBusy) return;
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Transcriber", "Recordings");
            var session = new RecordingSession(root);
            session.Updated += Recording_Updated;
            session.Faulted += Recording_Faulted;
            session.Start(captureSystemAudio: true);
            _recording = session;
            Vm.StatusMessage = null;
            IdleRecordingControls.Visibility = Visibility.Collapsed;
            ActiveRecordingControls.Visibility = Visibility.Visible;
            RecordingSource.Text = session.HasSystemAudio
                ? $"Mic: {session.MicDeviceName}  •  System: {session.SystemDeviceName}"
                : $"Mic: {session.MicDeviceName}  •  System audio unavailable";
            RecordingWarningText.Text = string.Empty;
            _recordingTimer.Start();
            RefreshRecordingUi();
        }
        catch (Exception error)
        {
            _recording?.Dispose();
            _recording = null;
            Vm.StatusMessage = "Could not start recording: " + error.Message;
        }
    }

    private void PauseRecording_Click(object sender, RoutedEventArgs e)
    {
        if (_recording is not { } recording) return;
        if (recording.State == RecordingState.Paused) recording.Resume();
        else recording.Pause();
        RefreshRecordingUi();
    }

    private async void StopRecording_Click(object sender, RoutedEventArgs e)
    {
        if (_recording is not { } recording) return;
        SetRecordingButtonsEnabled(false);
        RecordingSource.Text = "Saving recording…";
        RecordingWarningText.Text = "This can take a moment for a long meeting.";
        try
        {
            var result = await recording.StopAndFinalizeAsync(_tools.FFmpeg);
            RecordingSource.Text = "Transcribing recording…";
            RecordingWarningText.Text = result.Warning ?? string.Empty;
            await Vm.ImportAsync(
                result.FinalPath,
                _tools,
                language: "auto",
                vocabulary: null,
                recordingWarning: result.Warning,
                tracks: result.SourceTracks.Select(Path.GetFileName).OfType<string>().ToList());
            Vm.SelectedItem = Vm.Items.FirstOrDefault();
            ItemsList.SelectedItem = Vm.SelectedItem;
        }
        catch (Exception error)
        {
            Vm.StatusMessage = "Could not save recording: " + error.Message;
        }
        finally
        {
            recording.Updated -= Recording_Updated;
            recording.Faulted -= Recording_Faulted;
            recording.Dispose();
            _recording = null;
            SetIdleRecordingUi();
        }
    }

    private async void DiscardRecording_Click(object sender, RoutedEventArgs e)
    {
        if (_recording is not { } recording) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Discard this recording?",
            Content = "The microphone and system-audio tracks from this recording will be deleted.",
            PrimaryButtonText = "Discard",
            CloseButtonText = "Keep recording",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        SetRecordingButtonsEnabled(false);
        try { await recording.DiscardAsync(); }
        finally
        {
            recording.Dispose();
            _recording = null;
            Vm.StatusMessage = "Recording discarded.";
            SetIdleRecordingUi();
        }
    }

    private void Recording_Updated(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueue(RefreshRecordingUi);

    private void Recording_Faulted(object? sender, string message) =>
        DispatcherQueue.TryEnqueue(() => RecordingWarningText.Text = "Capture error: " + message);

    private void RefreshRecordingUi()
    {
        if (_recording is not { } recording) return;
        RecordingTime.Text = FormatElapsed(recording.Elapsed);
        MicLevel.Value = recording.MicLevel * 100;
        var paused = recording.State == RecordingState.Paused;
        PauseRecordingButton.Content = paused ? "Resume" : "Pause";
        RecordingDot.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
            paused ? Microsoft.UI.Colors.Orange : Microsoft.UI.Colors.Red);
        var warning = recording.HealthWarning(DateTimeOffset.UtcNow);
        if (warning is not null) RecordingWarningText.Text = warning;
    }

    private void SetRecordingButtonsEnabled(bool enabled)
    {
        PauseRecordingButton.IsEnabled = enabled;
        DiscardRecordingButton.IsEnabled = enabled;
        StopRecordingButton.IsEnabled = enabled;
    }

    private void SetIdleRecordingUi()
    {
        _recordingTimer.Stop();
        ActiveRecordingControls.Visibility = Visibility.Collapsed;
        IdleRecordingControls.Visibility = Visibility.Visible;
        SetRecordingButtonsEnabled(true);
        MicLevel.Value = 0;
    }

    private static string FormatElapsed(TimeSpan elapsed) => elapsed.TotalHours >= 1
        ? elapsed.ToString(@"h\:mm\:ss")
        : elapsed.ToString(@"mm\:ss");

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (Vm.IsBusy) return;
        var picker = new FileOpenPicker { ViewMode = PickerViewMode.List };
        foreach (var ext in new[] { ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".flac", ".mp4", ".mov", ".mkv", ".webm" })
        {
            picker.FileTypeFilter.Add(ext);
        }
        InitializeWithWindow(picker);
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        var expectedSpeakers = await PromptForSpeakerCountAsync();
        if (expectedSpeakers is null) return;
        await Vm.ImportAsync(file.Path, _tools, language: "auto", vocabulary: null,
            expectedSpeakers: expectedSpeakers.Value);
    }

    private void CancelProcessing_Click(object sender, RoutedEventArgs e)
    {
        Vm.CancelProcessing();
    }

    private async void NewProject_Click(object sender, RoutedEventArgs e)
    {
        var name = await PromptForTextAsync("New Project", "Project name", "");
        if (!string.IsNullOrWhiteSpace(name)) Vm.CreateProject(name!.Trim());
    }

    // MARK: - Item context actions

    private static TranscriptItemViewModel? ItemOf(object sender) =>
        (sender as FrameworkElement)?.DataContext as TranscriptItemViewModel;

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } vm) return;
        var file = await StorageFile.GetFileFromPathAsync(Vm.Store.TranscriptPath(vm.Item));
        await Windows.System.Launcher.LaunchFileAsync(file);
    }

    private void ExportTranscriptDownloads_Click(object sender, RoutedEventArgs e) =>
        ExportToDownloads(ItemOf(sender), ExportKind.Transcript);

    private void ExportAudioDownloads_Click(object sender, RoutedEventArgs e) =>
        ExportToDownloads(ItemOf(sender), ExportKind.Audio);

    private async void ExportTranscriptAs_Click(object sender, RoutedEventArgs e) =>
        await ExportWithPickerAsync(ItemOf(sender), ExportKind.Transcript);

    private void ExportToDownloads(TranscriptItemViewModel? vm, ExportKind kind)
    {
        if (vm is null) return;
        try
        {
            var downloads = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            var destination = Path.Combine(downloads, Vm.ExportName(vm, kind));
            Vm.Export(vm.Id, kind, destination);
            Vm.StatusMessage = $"Saved to {destination}";
        }
        catch (Exception ex)
        {
            Vm.StatusMessage = $"Export failed: {ex.Message}";
        }
    }

    private async Task ExportWithPickerAsync(TranscriptItemViewModel? vm, ExportKind kind)
    {
        if (vm is null) return;
        var picker = new FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(Vm.ExportName(vm, kind)) };
        var ext = Path.GetExtension(Vm.ExportName(vm, kind));
        picker.FileTypeChoices.Add(kind == ExportKind.Transcript ? "Markdown" : "Audio", [ext]);
        InitializeWithWindow(picker);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try { Vm.Export(vm.Id, kind, file.Path); Vm.StatusMessage = $"Saved to {file.Path}"; }
        catch (Exception ex) { Vm.StatusMessage = $"Export failed: {ex.Message}"; }
    }

    private async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } vm) return;
        var name = await PromptForTextAsync("Rename", "Title", vm.Title);
        if (!string.IsNullOrWhiteSpace(name)) { Vm.RenameItem(vm.Id, name!.Trim()); UpdateDetail(Vm.SelectedItem); }
    }

    private async void RenameSpeakers_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } vm || vm.Item.Speakers.Count == 0) return;
        var inputs = vm.Item.Speakers.Select(speaker => new TextBox
        {
            Header = speaker,
            Text = speaker,
            PlaceholderText = "Speaker name",
        }).ToList();
        var form = new StackPanel { Spacing = 10 };
        foreach (var input in inputs) form.Children.Add(input);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Rename speakers",
            Content = form,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        Vm.RenameSpeakers(vm.Id, vm.Item.Speakers
            .Select((speaker, index) => (speaker, inputs[index].Text))
            .ToDictionary(pair => pair.speaker, pair => pair.Text));
        ItemsList.SelectedItem = Vm.Items.FirstOrDefault(item => item.Id == vm.Id);
        UpdateDetail(Vm.SelectedItem);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } vm) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Delete permanently?",
            Content = $"“{vm.Title}” and its audio copy will be removed. Your original file is not affected.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            Vm.DeleteItem(vm.Id);
            UpdateDetail(Vm.SelectedItem);
        }
    }

    // MARK: - Helpers

    private async Task<string?> PromptForTextAsync(string title, string placeholder, string initial)
    {
        var input = new TextBox { PlaceholderText = placeholder, Text = initial };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = title,
            Content = input,
            PrimaryButtonText = "OK",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? input.Text : null;
    }

    private async Task<int?> PromptForSpeakerCountAsync()
    {
        var selector = new ComboBox { Header = "How many people are speaking?", SelectedIndex = 1 };
        foreach (var option in new[]
        {
            ("Auto-detect (experimental)", -1), ("2 speakers", 2), ("3 speakers", 3),
            ("4 speakers", 4), ("5 speakers", 5), ("6 speakers", 6),
        })
            selector.Items.Add(new ComboBoxItem { Content = option.Item1, Tag = option.Item2 });
        var explanation = new TextBlock
        {
            Text = "Choosing the count is more reliable for compressed meeting recordings.",
            TextWrapping = TextWrapping.Wrap,
        };
        var content = new StackPanel { Spacing = 10 };
        content.Children.Add(explanation);
        content.Children.Add(selector);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Speaker detection",
            Content = content,
            PrimaryButtonText = "Transcribe",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        return selector.SelectedItem is ComboBoxItem item && item.Tag is int count ? count : -1;
    }

    /// <summary>Unpackaged pickers/dialogs need the owning window handle.</summary>
    private void InitializeWithWindow(object target)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(target, hwnd);
    }
}
