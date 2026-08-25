<#
    Downloads the binaries and models the app ships with, into Windows\bin and Windows\models.

    Run inside the Windows VM (or on any Windows machine) from the repo's Windows folder:
        powershell -ExecutionPolicy Bypass -File scripts\fetch-assets.ps1

    ffmpeg is deliberately the LGPL build: the Homebrew/GPL builds used during macOS
    development are not redistributable in a commercial product.

    Note: whisper.cpp publishes no prebuilt Vulkan binary, and Vulkan is the whole integrated-GPU
    story for the GPU-less business laptops our buyers use. The CPU build fetched here is the
    baseline; building whisper.cpp with -DGGML_VULKAN=ON is a separate step (see README.md).
#>
[CmdletBinding()]
param(
    [switch]$IncludeModel = $true,
    [switch]$IncludeDiarization = $true,
    [string]$WhisperVersion = 'v1.9.2'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$binDir   = Join-Path $root 'bin'
$modelDir = Join-Path $root 'models'
$cacheDir = Join-Path $env:TEMP 'transcriber-assets'

foreach ($dir in @($binDir, $modelDir, $cacheDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$modelName = 'ggml-large-v3-turbo-q5_0.bin'
$fastModelName = 'ggml-small-q5_1.bin'
$balancedModelName = 'ggml-medium-q5_0.bin'
$vadName   = 'ggml-silero-v5.1.2.bin'

function Get-Asset {
    param([string]$Url, [string]$Destination, [string]$Label)

    if (Test-Path $Destination) {
        Write-Host "  $Label — already present" -ForegroundColor DarkGray
        return
    }
    Write-Host "  $Label ..." -ForegroundColor Cyan
    $partial = "$Destination.part"
    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadFile($Url, $partial)
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Write-Host "  $Label — done" -ForegroundColor Green
    } catch {
        if (Test-Path $partial) { Remove-Item -LiteralPath $partial -Force }
        throw "could not download $Label from $Url : $($_.Exception.Message)"
    } finally {
        $client.Dispose()
    }
}

function Expand-Executables {
    param([string]$Archive, [string]$Target)

    # Both archives nest their payload (Release\ for whisper, a versioned bin\ for ffmpeg),
    # so flatten every .exe and .dll into one folder the app can reference directly.
    $staging = Join-Path $cacheDir ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $Archive -DestinationPath $staging -Force
        $found = Get-ChildItem -Path $staging -Recurse -Include *.exe, *.dll
        foreach ($file in $found) {
            Copy-Item -LiteralPath $file.FullName -Destination $Target -Force
        }
        Write-Host "  extracted $($found.Count) files" -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n== ffmpeg (LGPL build) ==" -ForegroundColor White
$ffmpegZip = Join-Path $cacheDir 'ffmpeg-lgpl.zip'
Get-Asset 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip' `
    $ffmpegZip 'ffmpeg win64 lgpl'
if (-not (Test-Path (Join-Path $binDir 'ffmpeg.exe'))) {
    Expand-Executables $ffmpegZip $binDir
}

Write-Host "`n== whisper.cpp $WhisperVersion (CPU) ==" -ForegroundColor White
$whisperZip = Join-Path $cacheDir "whisper-$WhisperVersion.zip"
Get-Asset "https://github.com/ggml-org/whisper.cpp/releases/download/$WhisperVersion/whisper-bin-x64.zip" `
    $whisperZip 'whisper-bin-x64'
if (-not (Test-Path (Join-Path $binDir 'whisper-cli.exe'))) {
    Expand-Executables $whisperZip $binDir
}

Write-Host "`n== models ==" -ForegroundColor White
Get-Asset "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$vadName" `
    (Join-Path $modelDir $vadName) 'silero VAD (~1 MB)'
if ($IncludeModel) {
    Get-Asset "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$fastModelName" `
        (Join-Path $modelDir $fastModelName) 'small q5_1 — Faster (~182 MB)'
    Get-Asset "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$balancedModelName" `
        (Join-Path $modelDir $balancedModelName) 'medium q5_0 — Balanced (~515 MB)'
    Get-Asset "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$modelName" `
        (Join-Path $modelDir $modelName) 'large-v3-turbo q5_0 (~574 MB, slow)'
}
if ($IncludeDiarization) {
    $segmentationName = 'pyannote-segmentation-3.0.onnx'
    $embeddingName = '3dspeaker-eres2net-base-16k.onnx'
    $segmentationPath = Join-Path $modelDir $segmentationName
    if (-not (Test-Path $segmentationPath)) {
        $archive = Join-Path $cacheDir 'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2'
        Get-Asset 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2' `
            $archive 'pyannote speaker segmentation (~6 MB)'
        $staging = Join-Path $cacheDir ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            & tar.exe -xf $archive -C $staging
            if ($LASTEXITCODE -ne 0) { throw 'tar could not extract the diarization model' }
            $model = Get-ChildItem $staging -Recurse -Filter model.onnx | Select-Object -First 1
            if (-not $model) { throw 'the diarization archive did not contain model.onnx' }
            Copy-Item -LiteralPath $model.FullName -Destination $segmentationPath
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Get-Asset 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx' `
        (Join-Path $modelDir $embeddingName) '3D-Speaker embedding model (~28 MB)'
}

Write-Host "`n== check ==" -ForegroundColor White
$missing = @()
foreach ($required in @(
    (Join-Path $binDir 'ffmpeg.exe'),
    (Join-Path $binDir 'whisper-cli.exe'),
    (Join-Path $modelDir $vadName)
)) {
    if (Test-Path $required) {
        Write-Host "  ok   $required" -ForegroundColor Green
    } else {
        Write-Host "  MISSING $required" -ForegroundColor Red
        $missing += $required
    }
}
if ($missing.Count -gt 0) { exit 1 }

Write-Host "`nAssets ready. Smoke-test the pipeline with:" -ForegroundColor White
Write-Host "  dotnet run --project src\Transcriber.Cli -- <some.m4a> --language ru" -ForegroundColor DarkGray
