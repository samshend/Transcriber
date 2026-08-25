[CmdletBinding()]
param(
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'

$windowsRoot = Split-Path -Parent $PSScriptRoot
$publishDir = Join-Path $windowsRoot 'artifacts\friend-test\publish'
$project = Join-Path $windowsRoot 'src\Transcriber.App\Transcriber.App.csproj'
$installerScript = Join-Path $windowsRoot 'installer\Transcriber.iss'
$setupExe = Join-Path $windowsRoot 'artifacts\friend-test\Transcriber-Windows-0.1.0-Friend-Test-Setup.exe'
$iscc = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'

if (-not $SkipPublish) {
    dotnet publish $project `
        --configuration Release `
        --runtime win-x64 `
        --self-contained true `
        -p:SelfContained=true `
        -p:PublishSingleFile=false `
        -p:DebugType=None `
        -p:DebugSymbols=false `
        --output $publishDir

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $publishDir 'Transcriber.App.exe'))) {
    throw "Publish output is missing. Run without -SkipPublish first."
}

if (-not (Test-Path -LiteralPath $iscc)) {
    throw "Inno Setup 6 was not found at '$iscc'. Install it with: winget install JRSoftware.InnoSetup"
}

# Transcriber.iss excludes publish\models and downloads verified models during installation.
& $iscc $installerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$setup = Get-Item -LiteralPath $setupExe
$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $setup.FullName

[pscustomobject]@{
    Installer = $setup.FullName
    SizeMiB = [math]::Round($setup.Length / 1MB, 1)
    SHA256 = $hash.Hash
}
