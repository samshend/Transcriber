namespace Transcriber.Core;

/// <summary>Pure recording finalization rules, kept in Core so failure messages and FFmpeg
/// behavior are deterministic and unit tested without audio hardware.</summary>
public static class RecordingPolicy
{
    public static IReadOnlyList<string> BuildFinalizeArguments(IReadOnlyList<string> inputs, string output)
    {
        if (inputs.Count is < 1 or > 2) throw new ArgumentOutOfRangeException(nameof(inputs));
        var result = new List<string> { "-hide_banner", "-nostdin", "-y" };
        foreach (var input in inputs) result.AddRange(["-i", input]);
        if (inputs.Count == 2)
        {
            result.AddRange([
                "-filter_complex",
                "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.97[a]",
                "-map", "[a]",
            ]);
        }
        result.AddRange(["-c:a", "aac", "-b:a", "192k", output]);
        return result;
    }

    public static string? BuildWarning(
        TimeSpan mic,
        TimeSpan system,
        bool haveMic,
        bool haveSystem,
        string? existing = null)
    {
        var warnings = new List<string>();
        if (!string.IsNullOrWhiteSpace(existing)) warnings.Add(existing);
        if (!haveMic) warnings.Add("No microphone audio was captured.");
        if (!haveSystem) warnings.Add("No system audio was captured; the other side of an online call may be missing.");
        if (haveMic && haveSystem && Math.Abs((mic - system).TotalSeconds) > 5)
        {
            var shorter = mic < system ? "microphone" : "system audio";
            warnings.Add($"The {shorter} track ended early ({Short(mic)} mic vs {Short(system)} system audio). Part of the call may be missing.");
        }
        return warnings.Count == 0 ? null : string.Join(" ", warnings);
    }

    private static string Short(TimeSpan value) => value.TotalHours >= 1
        ? value.ToString(@"h\:mm\:ss")
        : value.ToString(@"m\:ss");
}
