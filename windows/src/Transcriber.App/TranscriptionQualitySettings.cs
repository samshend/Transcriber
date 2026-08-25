using System.Text.Json;

namespace Transcriber.App;

internal enum TranscriptionQuality { Faster = 0, Balanced = 1, MoreAccurate = 2 }

internal sealed record TranscriptionModelOption(
    TranscriptionQuality Quality,
    string Title,
    string Description,
    string FileName,
    string DownloadUrl,
    string Sha256,
    long DownloadBytes);

internal static class TranscriptionModels
{
    public static readonly IReadOnlyList<TranscriptionModelOption> All =
    [
        new(TranscriptionQuality.Faster, "Faster", "Small multilingual model · lower accuracy · ~182 MB",
            "ggml-small-q5_1.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin",
            "AE85E4A935D7A567BD102FE55AFC16BB595BDB618E11B2FC7591BC08120411BB", 190085487),
        new(TranscriptionQuality.Balanced, "Balanced", "Medium multilingual model · balanced speed and accuracy · ~515 MB",
            "ggml-medium-q5_0.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin",
            "19FEA4B380C3A618EC4723C3EEF2EB785FFBA0D0538CF43F8F235E7B3B34220F", 539212467),
        new(TranscriptionQuality.MoreAccurate, "More accurate", "Large v3 Turbo · slowest on this laptop · ~547 MB",
            "ggml-large-v3-turbo-q5_0.bin",
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
            "394221709CD5AD1F40C46E6031CA61BCE88931E6E088C188294C6D5A55FFA7E2", 574041195),
    ];

    public static TranscriptionModelOption Get(TranscriptionQuality quality) => All[(int)quality];
}

internal static class ModelDownloader
{
    private static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };

    public static async Task DownloadAsync(
        TranscriptionModelOption model,
        string destination,
        IProgress<double>? progress,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temporary = destination + ".download";
        try
        {
            using var response = await Client.GetAsync(
                model.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength ?? model.DownloadBytes;
            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using (var target = new FileStream(
                temporary, FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                var buffer = new byte[1024 * 1024];
                long received = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
                    received += count;
                    progress?.Report(total > 0 ? received * 100d / total : 0);
                }
            }

            if (new FileInfo(temporary).Length != model.DownloadBytes)
                throw new InvalidDataException("The downloaded model has an unexpected size.");
            string hash;
            await using (var verificationStream = File.OpenRead(temporary))
            {
                hash = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(
                    verificationStream, cancellationToken));
            }
            if (!hash.Equals(model.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The downloaded model failed its integrity check.");

            File.Move(temporary, destination, overwrite: true);
            progress?.Report(100);
        }
        finally
        {
            try { File.Delete(temporary); } catch { }
        }
    }
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
