using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Transcriber.Core;

namespace Transcriber.App;

public enum RecordingState { Idle, Starting, Recording, Paused, Finalizing, Complete, Faulted }

public sealed record FinishedRecording(
    string FinalPath,
    IReadOnlyList<string> SourceTracks,
    TimeSpan MicDuration,
    TimeSpan SystemDuration,
    string? Warning);

/// <summary>
/// Owns one Windows recording. Microphone and render-loopback are intentionally written to
/// separate WAV files: a mix can be regenerated, and a failure on one side cannot destroy the
/// other side of a client call.
/// </summary>
public sealed class RecordingSession : IDisposable
{
    private readonly object _gate = new();
    private readonly Stopwatch _elapsed = new();
    private readonly string _folder;
    private WasapiRecorder? _mic;
    private WasapiRecorder? _system;
    private WaveFileWriter? _micWriter;
    private WaveFileWriter? _systemWriter;
    private DateTimeOffset _lastMicBuffer;
    private DateTimeOffset _lastSystemBuffer;
    private bool _disposed;
    private string? _startupWarning;

    public RecordingState State { get; private set; } = RecordingState.Idle;
    public string MicPath { get; }
    public string SystemPath { get; }
    public string FinalPath { get; }
    public TimeSpan Elapsed => _elapsed.Elapsed;
    public float MicLevel { get; private set; }
    public bool HasSystemAudio => _system is not null;
    public string MicDeviceName => _mic?.DeviceFriendlyName ?? "Default microphone";
    public string SystemDeviceName => _system?.DeviceFriendlyName ?? "Default output";
    public DateTimeOffset LastMicBuffer => _lastMicBuffer;
    public DateTimeOffset LastSystemBuffer => _lastSystemBuffer;

    public event EventHandler? Updated;
    public event EventHandler<string>? Faulted;

    public RecordingSession(string recordingsRoot)
    {
        var stamp = DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss");
        _folder = UniqueFolder(recordingsRoot, "Recording " + stamp);
        Directory.CreateDirectory(_folder);
        MicPath = Path.Combine(_folder, "microphone.wav");
        SystemPath = Path.Combine(_folder, "system.wav");
        FinalPath = Path.Combine(_folder, Path.GetFileName(_folder) + ".m4a");
    }

    public void Start(bool captureSystemAudio = true)
    {
        if (State != RecordingState.Idle) throw new InvalidOperationException("Recording already started.");
        State = RecordingState.Starting;
        try
        {
            _mic = CreateMicrophoneCapture();
            _micWriter = new WaveFileWriter(MicPath, _mic.WaveFormat);
            _mic.DataAvailable += MicDataAvailable;
            _mic.RecordingStopped += CaptureStopped;

            if (captureSystemAudio)
            {
                try
                {
                    _system = CreateLoopbackCapture();
                    _systemWriter = new WaveFileWriter(SystemPath, _system.WaveFormat);
                    _system.DataAvailable += SystemDataAvailable;
                    _system.RecordingStopped += CaptureStopped;
                }
                catch (Exception error)
                {
                    _system?.Dispose();
                    _system = null;
                    _systemWriter?.Dispose();
                    _systemWriter = null;
                    _startupWarning = "System audio could not be captured; this recording contains microphone audio only: " + error.Message;
                }
            }

            _lastMicBuffer = _lastSystemBuffer = DateTimeOffset.UtcNow;
            _mic.StartRecording();
            _system?.StartRecording();
            _elapsed.Start();
            State = RecordingState.Recording;
            Updated?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            State = RecordingState.Faulted;
            DisposeCaptures();
            throw;
        }
    }

    private static WasapiRecorder CreateMicrophoneCapture()
    {
        using var enumerator = new MMDeviceEnumerator();
        var endpoint = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        return new WasapiRecorderBuilder()
            .WithDevice(endpoint)
            .WithSharedMode()
            .WithEventSync()
            .WithBufferLength(100)
            .WithMmcssThreadPriority("Capture")
            .Build();
    }

    private static WasapiRecorder CreateLoopbackCapture()
    {
        using var enumerator = new MMDeviceEnumerator();
        var endpoint = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        return new WasapiRecorderBuilder()
            .WithDevice(endpoint)
            .WithSharedMode()
            .WithEventSync()
            .WithLoopbackCapture()
            .WithBufferLength(100)
            .WithMmcssThreadPriority("Capture")
            .Build();
    }

    public void Pause()
    {
        if (State != RecordingState.Recording) return;
        State = RecordingState.Paused;
        _elapsed.Stop();
        Updated?.Invoke(this, EventArgs.Empty);
    }

    public void Resume()
    {
        if (State != RecordingState.Paused) return;
        State = RecordingState.Recording;
        _elapsed.Start();
        Updated?.Invoke(this, EventArgs.Empty);
    }

    public async Task<FinishedRecording> StopAndFinalizeAsync(string ffmpeg, CancellationToken cancellationToken = default)
    {
        if (State is not (RecordingState.Recording or RecordingState.Paused))
            throw new InvalidOperationException("No recording is in progress.");

        State = RecordingState.Finalizing;
        _elapsed.Stop();
        Updated?.Invoke(this, EventArgs.Empty);
        await StopCapturesAsync().ConfigureAwait(false);

        var micDuration = DurationOf(_micWriter);
        var systemDuration = DurationOf(_systemWriter);
        DisposeWriters();

        var haveMic = micDuration.TotalMilliseconds >= 250;
        var haveSystem = systemDuration.TotalMilliseconds >= 250;
        if (!haveMic && !haveSystem)
        {
            State = RecordingState.Faulted;
            throw new InvalidDataException("No audio was captured. Check the Windows microphone privacy setting and selected devices.");
        }

        var inputs = new List<string>();
        if (haveMic) inputs.Add(MicPath);
        if (haveSystem) inputs.Add(SystemPath);
        var arguments = RecordingPolicy.BuildFinalizeArguments(inputs, FinalPath);
        await ProcessRunner.RunOrThrowAsync(ffmpeg, arguments, "ffmpeg", cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        var warning = RecordingPolicy.BuildWarning(micDuration, systemDuration, haveMic, haveSystem, _startupWarning);
        State = RecordingState.Complete;
        Updated?.Invoke(this, EventArgs.Empty);
        return new FinishedRecording(FinalPath, inputs, micDuration, systemDuration, warning);
    }

    public async Task DiscardAsync()
    {
        _elapsed.Stop();
        await StopCapturesAsync().ConfigureAwait(false);
        DisposeWriters();
        DisposeCaptures();
        try { Directory.Delete(_folder, recursive: true); } catch { }
        State = RecordingState.Idle;
    }

    public string? HealthWarning(DateTimeOffset now)
    {
        if (State != RecordingState.Recording) return null;
        if (now - _lastMicBuffer > TimeSpan.FromSeconds(3))
            return "Microphone is not delivering audio. Check the input device before continuing.";
        return null;
    }

    private void MicDataAvailable(ReadOnlySpan<byte> buffer, AudioClientBufferFlags flags, long devicePosition, long qpcPosition)
    {
        lock (_gate)
        {
            _lastMicBuffer = DateTimeOffset.UtcNow;
            if (State == RecordingState.Recording)
            {
                _micWriter?.Write(buffer);
                var measured = Peak(buffer, _mic?.WaveFormat);
                MicLevel = Math.Max(measured, MicLevel * 0.72f);
            }
        }
        Updated?.Invoke(this, EventArgs.Empty);
    }

    private void SystemDataAvailable(ReadOnlySpan<byte> buffer, AudioClientBufferFlags flags, long devicePosition, long qpcPosition)
    {
        lock (_gate)
        {
            _lastSystemBuffer = DateTimeOffset.UtcNow;
            if (State == RecordingState.Recording)
                _systemWriter?.Write(buffer);
        }
    }

    private void CaptureStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null && State is RecordingState.Recording or RecordingState.Paused)
        {
            State = RecordingState.Faulted;
            Faulted?.Invoke(this, args.Exception.Message);
        }
    }

    private async Task StopCapturesAsync()
    {
        var waits = new List<Task>();
        if (_mic is not null) waits.Add(StopOneAsync(_mic));
        if (_system is not null) waits.Add(StopOneAsync(_system));
        if (waits.Count > 0)
            await Task.WhenAll(waits).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    private static Task StopOneAsync(WasapiRecorder capture)
    {
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<StoppedEventArgs>? handler = null;
        handler = (_, _) =>
        {
            capture.RecordingStopped -= handler;
            stopped.TrySetResult();
        };
        capture.RecordingStopped += handler;
        try { capture.StopRecording(); }
        catch { capture.RecordingStopped -= handler; stopped.TrySetResult(); }
        return stopped.Task;
    }

    private static TimeSpan DurationOf(WaveFileWriter? writer) => writer?.TotalTime ?? TimeSpan.Zero;

    private static float Peak(ReadOnlySpan<byte> data, WaveFormat? format)
    {
        if (format is null || data.Length < 2) return 0;
        var peak = 0f;
        var sampleFormat = format.AsStandardWaveFormat();
        // WASAPI commonly reports 32-bit float inside either a materialized extensible format
        // or raw extra-data headers. The captured WAV/ffmpeg probe is authoritative here: the
        // 32-bit shared-mode endpoints used by Windows carry IEEE samples.
        if (sampleFormat.BitsPerSample == 32)
        {
            for (var i = 0; i + 3 < data.Length; i += 4)
            {
                var sample = Math.Abs(BitConverter.ToSingle(data[i..(i + 4)]));
                if (float.IsFinite(sample)) peak = Math.Max(peak, sample);
            }
        }
        else if (sampleFormat.Encoding == WaveFormatEncoding.Pcm && sampleFormat.BitsPerSample == 16)
        {
            for (var i = 0; i + 1 < data.Length; i += 2) peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(data[i..(i + 2)]) / 32768f));
        }
        return Math.Clamp(peak, 0, 1);
    }

    private static string UniqueFolder(string root, string name)
    {
        Directory.CreateDirectory(root);
        var candidate = Path.Combine(root, name);
        for (var suffix = 2; Directory.Exists(candidate); suffix++) candidate = Path.Combine(root, $"{name} {suffix}");
        return candidate;
    }

    private void DisposeWriters()
    {
        lock (_gate)
        {
            _micWriter?.Dispose();
            _systemWriter?.Dispose();
            _micWriter = null;
            _systemWriter = null;
        }
    }

    private void DisposeCaptures()
    {
        _mic?.Dispose();
        _system?.Dispose();
        _mic = null;
        _system = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _elapsed.Stop();
        try { _mic?.StopRecording(); } catch { }
        try { _system?.StopRecording(); } catch { }
        DisposeWriters();
        DisposeCaptures();
    }
}
