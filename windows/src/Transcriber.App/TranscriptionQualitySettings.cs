using System.Text.Json;

namespace Transcriber.App;

internal enum TranscriptionQuality { Faster = 0, Balanced = 1, MoreAccurate = 2 }

internal sealed record TranscriptionModelOption(
    TranscriptionQuality Quality,
    string Title,
    string Description,
    string FileName);

internal static class TranscriptionModels
{
    public static readonly IReadOnlyList<TranscriptionModelOption> All =
    [
        new(TranscriptionQuality.Faster, "Faster", "Small multilingual model · lower accuracy · ~182 MB",
            "ggml-small-q5_1.bin"),
        new(TranscriptionQuality.Balanced, "Balanced", "Medium multilingual model · balanced speed and accuracy · ~515 MB",
            "ggml-medium-q5_0.bin"),
        new(TranscriptionQuality.MoreAccurate, "More accurate", "Large v3 Turbo · slowest on this laptop · ~547 MB",
            "ggml-large-v3-turbo-q5_0.bin"),
    ];

    public static TranscriptionModelOption Get(TranscriptionQuality quality) => All[(int)quality];
}

internal sealed class TranscriptionSettings
{
    public TranscriptionQuality Quality { get; set; } = TranscriptionQuality.MoreAccurate;

    private static string PathName => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Transcriber", "settings.json");

    public static TranscriptionSettings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<TranscriptionSettings>(File.ReadAllText(PathName)) ?? new();
        }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.WriteAllText(PathName, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
