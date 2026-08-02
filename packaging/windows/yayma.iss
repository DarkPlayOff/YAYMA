; Inno Setup script for YAYMA (Windows installer).
; Build locally:  iscc packaging\windows\yayma.iss
; The Release build output (src\build\windows\x64\runner\Release) must exist first
; (its yayma.exe already carries the version from src\pubspec.yaml, baked in by
; Flutter's build via Runner.rc's FLUTTER_VERSION_* macros).

#define AppName "YAYMA"
#define AppPublisher "DarkPlayOff"
#define AppURL "https://github.com/DarkPlayOff/YAYMA"
#define AppExeName "yayma.exe"
#define ReleaseDir "..\..\src\build\windows\x64\runner\Release"

; Auto-detected from the built exe's version resource; pass /DAppVersion=x.y.z.b
; on the ISCC command line to override (e.g. for a manual/dev build).
#ifndef AppVersion
#define AppVersion GetVersionNumbersString(ReleaseDir + "\" + AppExeName)
#endif

[Setup]
AppId={{6E4B6F0E-8C1E-4C9B-9C33-3E1B8F1A6D2E}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
; Matches the CreateMutex() name in windows/runner/main.cpp: lets Setup detect
; a running instance and prompt to close it before install/uninstall.
AppMutex=YandexMusicAppMutex_Unique_ID
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir=..\..\dist
OutputBaseFilename=yayma-windows-setup-{#AppVersion}
SetupIconFile=..\..\src\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\..\LICENSE
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
VersionInfoCompany={#AppPublisher}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
