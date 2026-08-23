using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Transcriber.App.ViewModels;
using Transcriber.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Media.Core;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Transcriber.App;

public sealed partial class MainWindow : Window
{
    public LibraryViewModel Vm { get; }
    private readonly ToolPaths _tools;

    private const string ModelFile = "ggml-large-v3-turbo-q5_0.bin";
    private const string VadFile = "ggml-silero-v5.1.2.bin";

    public MainWindow()
    {
        // The managed library lives under LocalAppData; bundled tools/models sit beside the app.
        var libraryRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Transcriber", "Library");
        Vm = new LibraryViewModel(new LibraryStore(libraryRoot));
        _tools = ToolPaths.FromAppDirectory(AppContext.BaseDirectory, ModelFile, VadFile);

        InitializeComponent();
        NavList.SelectedIndex = 0;   // "All"
        UpdateDetail(null);
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
        var hasSelection = vm is not null;
        EmptyDetail.Visibility = hasSelection ? Visibility.Collapsed : Visibility.Visible;
        DetailTitle.Visibility = DetailMeta.Visibility = DetailBody.Visibility =
            hasSelection ? Visibility.Visible : Visibility.Collapsed;

        if (vm is null)
        {
            AudioPlayer.Visibility = Visibility.Collapsed;
            AudioPlayer.Source = null;
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
        var audioPath = Vm.Store.AudioPath(vm.Item);
        if (audioPath is not null && File.Exists(audioPath))
        {
            var file = await StorageFile.GetFileFromPathAsync(audioPath);
            AudioPlayer.Source = MediaSource.CreateFromStorageFile(file);
            AudioPlayer.Visibility = Visibility.Visible;
        }
        else
        {
            AudioPlayer.Source = null;
            AudioPlayer.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>Drops the leading <c>--- … ---</c> block for a readable preview.</summary>
    private static string StripFrontmatter(string content)
    {
        if (!content.StartsWith("---")) return content.Trim();
        var end = content.IndexOf("\n---", 3, StringComparison.Ordinal);
        return end < 0 ? content.Trim() : content[(end + 4)..].Trim();
    }

    // MARK: - Toolbar actions

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { ViewMode = PickerViewMode.List };
        foreach (var ext in new[] { ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".flac", ".mp4", ".mov", ".mkv", ".webm" })
        {
            picker.FileTypeFilter.Add(ext);
        }
        InitializeWithWindow(picker);
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await Vm.ImportAsync(file.Path, _tools, language: "auto", vocabulary: null);
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

    /// <summary>Unpackaged pickers/dialogs need the owning window handle.</summary>
    private void InitializeWithWindow(object target)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(target, hwnd);
    }
}
