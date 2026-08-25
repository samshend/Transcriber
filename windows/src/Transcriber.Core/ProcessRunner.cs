using System.Diagnostics;
using System.Text;

namespace Transcriber.Core;

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);

public sealed class ToolFailure(string tool, int exitCode, string stderrTail)
    : Exception(BuildMessage(tool, exitCode, stderrTail))
{
    public string Tool { get; } = tool;
    public int ExitCode { get; } = exitCode;

    private static string BuildMessage(string tool, int exitCode, string stderrTail)
    {
        var detail = stderrTail.Trim();
        return detail.Length == 0
            ? $"{tool} failed (exit code {exitCode})"
            : $"{tool}: {detail}";
    }
}

public static class ProcessRunner
{
    /// <summary>
    /// Runs a tool to completion, capturing both streams. stderr lines are surfaced as they
    /// arrive so progress can be reported while a long transcription is still running.
    /// </summary>
    public static async Task<ProcessResult> RunAsync(
        string executable,
        IEnumerable<string> arguments,
        Action<string>? onStandardErrorLine = null,
        CancellationToken cancellationToken = default)
    {
        var info = new ProcessStartInfo(executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = info };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        // Reading both streams via events avoids the classic deadlock where a full pipe
        // buffer blocks the child while the parent waits for it to exit.
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stderr.AppendLine(e.Data);
            onStandardErrorLine?.Invoke(e.Data);
        };

        if (!process.Start())
        {
            throw new ToolFailure(Path.GetFileName(executable), -1, "could not start the process");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.StandardInput.Close();

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { /* already gone */ }
            try
            {
                if (!process.HasExited)
                    await process.WaitForExitAsync(CancellationToken.None)
                        .WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None)
                        .ConfigureAwait(false);
            }
            catch { /* shutdown remains best-effort after the tree termination request */ }
            throw;
        }

        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    public static async Task<ProcessResult> RunOrThrowAsync(
        string executable,
        IEnumerable<string> arguments,
        string toolName,
        Action<string>? onStandardErrorLine = null,
        CancellationToken cancellationToken = default)
    {
        var result = await RunAsync(executable, arguments, onStandardErrorLine, cancellationToken)
            .ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            var tail = result.StandardError.Length > 300
                ? result.StandardError[^300..]
                : result.StandardError;
            throw new ToolFailure(toolName, result.ExitCode, tail);
        }
        return result;
    }
}
