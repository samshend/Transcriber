#define AppName "Transcriber"
#define AppVersion "0.1.0-friend-test"
#define Publisher "Transcriber"
#define AppExeName "Transcriber.App.exe"

[Setup]
AppId={{20F535E2-E3EA-4F65-9CA4-77F88AC71FD4}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#Publisher}
DefaultDirName={localappdata}\Programs\Transcriber
DefaultGroupName=Transcriber
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#SourcePath}\..\artifacts\friend-test
OutputBaseFilename=Transcriber-Windows-0.1.0-Friend-Test-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoVersion=0.1.0.0
VersionInfoProductName={#AppName}
VersionInfoDescription=Private offline meeting recorder and transcriber

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
; Models are intentionally excluded from the setup executable. Setup downloads only the selected
; transcription model and the three small models required for VAD/speaker diarization.
Source: "{#SourcePath}\..\artifacts\friend-test\publish\*"; DestDir: "{app}"; Excludes: "\models\*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourcePath}\FRIEND-TEST.md"; DestDir: "{app}"; DestName: "START HERE.txt"; Flags: ignoreversion
Source: "{#SourcePath}\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin"; DestDir: "{app}\models"; DestName: "ggml-small-q5_1.bin"; ExternalSize: 190085487; Hash: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"; Flags: external download ignoreversion onlyifdoesntexist; Check: IsFasterModel
Source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"; DestDir: "{app}\models"; DestName: "ggml-medium-q5_0.bin"; ExternalSize: 539212467; Hash: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"; Flags: external download ignoreversion onlyifdoesntexist; Check: IsBalancedModel
Source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"; DestDir: "{app}\models"; DestName: "ggml-large-v3-turbo-q5_0.bin"; ExternalSize: 574041195; Hash: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"; Flags: external download ignoreversion onlyifdoesntexist; Check: IsAccurateModel
Source: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"; DestDir: "{app}\models"; DestName: "ggml-silero-v5.1.2.bin"; ExternalSize: 885098; Hash: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"; Flags: external download ignoreversion onlyifdoesntexist
Source: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx"; DestDir: "{app}\models"; DestName: "pyannote-segmentation-3.0.onnx"; ExternalSize: 5992913; Hash: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"; Flags: external download ignoreversion onlyifdoesntexist
Source: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"; DestDir: "{app}\models"; DestName: "3dspeaker-eres2net-base-16k.onnx"; ExternalSize: 39593761; Hash: "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b"; Flags: external download ignoreversion onlyifdoesntexist

[Icons]
Name: "{group}\Transcriber"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{group}\Start Here"; Filename: "{app}\START HERE.txt"
Name: "{autodesktop}\Transcriber"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Transcriber"; Flags: nowait postinstall skipifsilent

[Code]
var
  ModelPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin
  ModelPage := CreateInputOptionPage(wpSelectDir,
    'Choose transcription quality',
    'Setup downloads one transcription model',
    'Faster is recommended for this test and keeps the download smallest. ' +
    'You can reinstall later to choose another model. Speaker analysis adds about 45 MB.',
    True, False);
  ModelPage.Add('Faster - 182 MB (recommended)');
  ModelPage.Add('Balanced - 515 MB');
  ModelPage.Add('More accurate - 547 MB (slowest)');
  ModelPage.SelectedValueIndex := 0;
end;

function IsFasterModel: Boolean;
begin
  Result := ModelPage.SelectedValueIndex = 0;
end;

function IsBalancedModel: Boolean;
begin
  Result := ModelPage.SelectedValueIndex = 1;
end;

function IsAccurateModel: Boolean;
begin
  Result := ModelPage.SelectedValueIndex = 2;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SettingsDir: String;
  SettingsJson: String;
begin
  if CurStep = ssPostInstall then
  begin
    SettingsDir := ExpandConstant('{localappdata}\Transcriber');
    ForceDirectories(SettingsDir);
    SettingsJson := Format('{"Quality":%d}', [ModelPage.SelectedValueIndex]);
    SaveStringToFile(SettingsDir + '\settings.json', SettingsJson, False);
  end;
end;
